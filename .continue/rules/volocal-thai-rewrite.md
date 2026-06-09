# Volocal Thai Rewrite Rules for Continue

## Core Rules
- **Thai-First**: Default ASR language = "th". LLM system prompt should prioritize natural Thai conversation, handling code-switching to English when needed. Support noisy/multi-speaker via FluidAudio VAD/diarization.
- **STT Integration**: Use FluidAudio's Qwen3ASRManager (or equivalent). Prefer f32 model for accuracy/stability. Implement streaming/chunked transcription with proper audio buffer handling from SharedAudioEngine.
- **Preserve Architecture**: Do not break SharedAudioEngine, barge-in (revision guards), SentenceBuffer, VoicePipeline loop.
- **Model Management**: Update Models/ registry for Qwen3-ASR download (Hugging Face FluidInference link). Keep progress UI.
- **Performance**: Target real-time RTF <1.0. Monitor memory/thermal. Use ANE priority for STT.
- **Code Style**: Swift 6+, clean, documented. Follow existing patterns exactly where possible. Use async/await. 
- **Formatting Rule**: Comments in code MUST be placed on their own lines. Never use inline comments at the end of a statement.
- **Scope Rule**: Change ONLY what is requested. Do not rename, move, refactor, or add helper functions unless explicitly asked.
- **Incremental & Safe**: One module at a time (e.g., STT first, then integration). Verify dependencies (FluidAudio via SPM).

## Forbidden
- Do not change LLM or TTS engines.
- Do not introduce cloud dependencies.
- Avoid unnecessary refactoring unless it improves Thai performance/stability.
- Do not add unrequested helper functions or alter the existing structural layout of unrequested files.

## When Editing
- Read relevant files first if context is missing.
- Provide before/after diffs or full file when replacing. If providing the full file, list the changes in sequence.
- Flag potential issues (e.g., Thai CER nuances, autoregressive decoder latency in Qwen3-ASR).
- Suggest tests with noisy Thai audio samples.

## FluidAudio Qwen3-ASR Notes
- f32 recommended by Fluid for their conversion (autoregressive decoder overhead on int8).
- Supports language param ("th").
- Integrate with existing VAD/EOU logic or add diarization for multi-speaker.
- Check latest FluidAudio docs for exact API (Qwen3AsrManager, transcribe(), etc.).

