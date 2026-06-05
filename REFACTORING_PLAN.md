# Volocal Refactoring Plan
## FluidInference Migration + iOS Memory Efficiency + Thai ASR Extensibility

---

## Part 1 — Diagnosis: Why Is the App Loading GGUF Models?

### Root Cause

GGUF is **not** an ASR format — it is the model file format used by
**llama.cpp** for LLM (large language model) inference. The Volocal app
deliberately uses GGUF for one reason only:

```
STT (speech → text)  →  LLM (text → text)  →  TTS (text → speech)
     FluidAudio              llama.cpp             FluidAudio
   CoreML / ANE          Metal GPU (GGUF)        CoreML / CPU+GPU
```

The **STT and TTS layers are already fully FluidInference / FluidAudio**.
`Parakeet EOU` (streaming ASR) and `PocketTTS` both run via CoreML on the
Neural Engine — exactly as intended. The GGUF layer is the LLM in the
middle.

### Why llama.cpp / GGUF is used for the LLM

| Requirement | llama.cpp answer |
|---|---|
| Runs entirely on-device, no cloud | ✅ |
| Swift-callable via `llama.swift` SPM package | ✅ |
| Uses Metal GPU (leaves ANE for STT/TTS) | ✅ |
| Quantised to Q4_K_S (~1.26 GB for 2B params) | ✅ |
| Streaming token output for low-latency TTS start | ✅ |

**FluidAudio does not provide LLM capabilities** — it is purely an audio
AI SDK (ASR, TTS, VAD, diarization). There is no drop-in FluidInference
replacement for the LLM layer *today*.

### What this refactor addresses

1. **Introduce protocol interfaces** so both ASR and LLM are swappable
   at runtime without touching the pipeline core.
2. **Add Thai-capable ASR** via WhisperKit (Whisper CoreML, fully local,
   supports Thai / 99 languages) alongside the existing Parakeet EOU.
3. **iOS memory efficiency**: lazy loading, sequential pipeline startup,
   OS memory-pressure responses, and a smaller LLM fallback.
4. **Prepare Apple Foundation Models path** (iOS 26+) as a future
   GGUF-free LLM option once iOS 26 reaches broad adoption.

---

## Part 2 — Architecture After Refactor

```
┌──────────────────────────────────────────────────────────────────┐
│                         VoicePipeline                            │
│   Mic → SharedAudioEngine → ASRProvider → LLMProvider           │
│                               ↑               │                  │
│                          barge-in         SentenceBuffer         │
│                                               ↓                  │
│                                          TTSManager → Speaker    │
└──────────────────────────────────────────────────────────────────┘

ASRProvider (protocol)
  ├── ParakeetASRProvider   — FluidAudio EOU streaming (English, fast)
  └── WhisperASRProvider    — WhisperKit CoreML (Thai + 99 languages)

LLMProvider (protocol)
  ├── LlamaLLMProvider      — llama.cpp GGUF / Metal (current, keeps GPU)
  └── FoundationModelProvider — Apple Foundation Models (iOS 26+, no GGUF)
```

### Hardware budget after refactor

| Component | Provider | Chip | Peak RAM |
|---|---|---|---|
| STT — English | Parakeet EOU | ANE | ~200 MB |
| STT — Thai | Whisper Small | ANE/GPU | ~290 MB |
| LLM — default | Qwen3.5-2B Q4_K_S | GPU (Metal) | ~1.26 GB |
| LLM — lite | Qwen3.5-0.8B Q4_K_S | GPU (Metal) | ~520 MB |
| LLM — iOS 26+ | Apple Foundation Models | ANE/System | ~0 MB extra |
| TTS | PocketTTS | CoreML CPU+GPU | ~600 MB |
| **Total (default)** | | | **~2.06 GB** |
| **Total (lite LLM)** | | | **~1.3 GB** |

iPhone 15 memory budget is ~3 GB; both configurations fit comfortably.

---

## Part 3 — File-by-File Changes

### New files (this PR)

| File | Purpose |
|---|---|
| `STT/ASRProvider.swift` | Protocol + shared result types |
| `STT/ParakeetASRProvider.swift` | FluidAudio EOU adapter (replaces `STTManager`) |
| `STT/WhisperASRProvider.swift` | WhisperKit adapter for Thai / multilingual |
| `LLM/LLMProvider.swift` | Protocol + streaming token types |
| `LLM/LlamaLLMProvider.swift` | Refactored llama.swift adapter |
| `LLM/FoundationModelProvider.swift` | iOS 26 Apple Foundation Models stub |
| `App/MemoryPressureMonitor.swift` | `os_proc_available_memory` + `NSNotification` |
| `Models/ModelConfiguration.swift` | Single source of truth for all model metadata |
| `Models/ModelRegistry+Thai.swift` | Thai WhisperKit model entries |
| `Pipeline/VoicePipeline.swift` | Protocol-driven; drops concrete manager refs |

### Modified files

| File | Change |
|---|---|
| `project.yml` | Add WhisperKit SPM dependency |
| `App/VolocalApp.swift` | Pass `ModelConfiguration` to pipeline |
| `Models/ModelRegistry.swift` | Merge Thai entries |
| `Debug/MetricsOverlay.swift` | Show active ASR provider name |

---

## Part 4 — Thai ASR Strategy

FluidAudio's Parakeet models **do not support Thai**
(supported: 25 European + Japanese + Chinese). Thai requires a separate model.

### Chosen approach: WhisperKit (argmaxinc/WhisperKit)

- Fully local, CoreML-native, runs on ANE+GPU.
- Wraps OpenAI Whisper models converted to CoreML `.mlpackage`.
- Supports Thai (`th`) as one of 99 languages via `whisper-small` or
  `whisper-medium`.
- SPM-installable: `https://github.com/argmaxinc/WhisperKit`
- Model size: `openai_whisper-small` ≈ 290 MB; `openai_whisper-medium` ≈ 780 MB.
- Latency: ~400 ms first word on iPhone 15 (small); comparable to Parakeet
  for short utterances.

### Trade-off vs Parakeet EOU

| | Parakeet EOU | Whisper Small (WhisperKit) |
|---|---|---|
| Streaming | ✅ real-time EOU | ❌ chunk-based (VAD-gated) |
| Languages | English only | 99 languages incl. Thai |
| WER English | 4.87% | ~7% |
| WER Thai | ❌ N/A | ~8–12% (varies by dialect) |
| Chip | ANE only | ANE + GPU |
| Memory | ~200 MB | ~290 MB |

For the Thai use case we accept chunk-based transcription with Silero VAD
gating utterance boundaries (FluidAudio VAD is reused here).

---

## Part 5 — Memory Efficiency Changes

### 1. Sequential pipeline loading
Models are loaded in order of first-use, not all at app start.
```
App launch → load STT only
First speech detected → keep STT loaded, load LLM
LLM responds → start TTS synthesis (LLM may stay loaded for barge-in)
```

### 2. Memory-pressure tiering
`MemoryPressureMonitor` subscribes to both:
- `UIApplication.didReceiveMemoryWarningNotification`
- `os_proc_available_memory()` polled every 10 s

On **warning**, the pipeline unloads whichever model is NOT currently
mid-inference (priority: keep STT active > keep TTS active > unload LLM
and reload on next turn).

### 3. Lite LLM fallback
`ModelConfiguration.liteMode: Bool` switches from Qwen3.5-2B to
Qwen3.5-0.8B Q4_K_S (520 MB vs 1.26 GB). Automatically engaged when
`MemoryPressureMonitor.availableMemoryMB < 1500`.

### 4. Unload-on-background
`ScenePhase.background` → call `llmProvider.unload()`.
`ScenePhase.active` → reload lazily on next user turn.

---

## Part 6 — SPM Dependency Changes

```yaml
# project.yml additions
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    from: 0.14.5          # keep — already present
  llama.swift:
    url: https://github.com/mattt/llama.swift
    from: 1.7130.0        # keep — already present
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit  # NEW — Thai ASR
    from: 0.9.0
```

---

## Part 7 — Execution Order

1. ✅ Write protocols (`ASRProvider`, `LLMProvider`)
2. ✅ Write `ParakeetASRProvider` (wraps existing `STTManager` logic)
3. ✅ Write `WhisperASRProvider` (new Thai path)
4. ✅ Write `LlamaLLMProvider` (refactored `LLMManager`)
5. ✅ Write `FoundationModelProvider` (iOS 26 stub with availability guard)
6. ✅ Write `MemoryPressureMonitor`
7. ✅ Write `ModelConfiguration` (single source of truth)
8. ✅ Write `ModelRegistry+Thai` (WhisperKit model entries)
9. ✅ Rewrite `VoicePipeline` against protocols
10. ✅ Update `project.yml` SPM block
