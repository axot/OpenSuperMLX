# OpenSuperMLX

OpenSuperMLX is a macOS application that provides real-time audio transcription powered by [MLX](https://github.com/ml-explore/mlx-swift) on Apple Silicon. It offers a seamless way to record and transcribe audio with customizable settings and keyboard shortcuts.

<p align="center">
<img src="docs/image.png" width="400" />
</p>

## Features

- 🎙️ Real-time audio recording and transcription
- 🔴 Streaming transcription — see results as you speak
- 🧠 MLX-based transcription engine — download models directly from the app
- ⌨️ Global keyboard shortcuts — tap to toggle or hold to record, fully customizable
- 📁 Drag & drop audio files for transcription with queue processing
- 🎤 Microphone selection — switch between built-in, external, Bluetooth and iPhone (Apple Continuity) mics from the menu bar
- 🌍 Support for multiple languages with auto-detection
- 🇯🇵🇨🇳🇰🇷 Asian language autocorrect ([autocorrect](https://github.com/huacnlee/autocorrect))
- 🤖 AWS Bedrock LLM post-transcription correction (optional)
- 👋 First-launch onboarding flow

## Installation

### Homebrew (Recommended)

```bash
brew tap axot/tap
brew install --cask opensupermlx
```

### Manual

Download from [GitHub releases page](https://github.com/axot/OpenSuperMLX/releases).

### macOS Security Approval

Since OpenSuperMLX is not signed with an Apple Developer ID, macOS will block the app on first launch. You need to manually approve it:

1. Open the app — macOS will show a warning that it cannot be opened
2. Go to **System Settings → Privacy & Security**
3. Scroll down to the **Security** section — you'll see a message about OpenSuperMLX being blocked
4. Click **Open Anyway**
5. Confirm in the dialog that appears

You only need to do this once. After approval, the app will launch normally.

## Usage

### Keyboard Shortcuts

OpenSuperMLX supports two recording modes via a global keyboard shortcut — it works from any app:

| Shortcut | Action |
|---|---|
| `⌥`\`` (Option + Backtick) | Start/stop recording |
| `⌥⇧`\`` (Option + Shift + Backtick) | Start/stop recording with LLM correction |
| `Escape` | Cancel active recording |

### Recording Modes

The shortcut automatically switches between two modes based on how you press it:

- **Tap** (quick press & release) — Toggles recording on and off. Press once to start recording, press again to stop. The transcribed text is automatically pasted into the frontmost app.
- **Hold** (press and hold) — Records while the key is held down. Release to stop and the transcribed text is automatically pasted into the frontmost app.

> **Tip:** Shortcuts are fully customizable in **Settings → Shortcuts**.

## Requirements

- macOS 15.1+ (Apple Silicon/ARM64)

## Support

If you encounter any issues or have questions, please:
1. Check the existing issues in the repository
2. Create a new issue with detailed information about your problem
3. Include system information and logs when reporting bugs

## Building locally

To build locally, you'll need:

    git clone git@github.com:axot/OpenSuperMLX.git
    cd OpenSuperMLX
    git submodule update --init --recursive
    brew install cmake libomp rust ruby
    gem install xcpretty
    ./run.sh build

In case of problems, consult `.github/workflows/build.yml` which is our CI workflow
where the app gets built automatically on GitHub's CI.

## License

OpenSuperMLX is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Acknowledgments

OpenSuperMLX is forked from [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) by [@Starmel](https://github.com/Starmel). Thanks to the original project for providing the foundation for this work.

## Models

MLX models are downloaded automatically from Hugging Face when selected in the app. Built-in models:

- **Qwen3-ASR-0.6B-4bit** — Smallest model, fastest inference
- **Qwen3-ASR-1.7B-8bit** — Recommended balance of accuracy and speed
- **Qwen3-ASR-1.7B-bf16** — Highest quality, best accuracy

Custom models can be added via HuggingFace repository ID.
