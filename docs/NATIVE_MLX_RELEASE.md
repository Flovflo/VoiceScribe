# VoiceScribe Native MLX Release Notes

Ce document decrit la migration et les garde-fous qualite pour la version native Swift + MLX.

## Objectif

- Supprimer le backend Python ASR.
- Forcer l'usage du modele MLX: `mlx-community/Qwen3-ASR-1.7B-8bit`.
- Stabiliser l'UX HUD (une seule popup, lisible, sans artefacts noirs).
- Verrouiller la qualite avec des tests MLX, ASR, FR/EN.

## Architecture (etat actuel)

- `NativeASREngine` (actor) execute l'inference ASR en natif.
- `NativeASRService` expose l'etat vers `AppState`/UI.
- `AudioFeatureExtractor` supporte un backend MLX GPU.
- Le modele charge est strictement valide:
  - Collection `mlx-community/Qwen3-ASR`
  - Variante imposee `Qwen3-ASR-1.7B-8bit`

## Correctifs UX/HUD inclus

- Debounce hotkey a deux niveaux:
  - Gate temporelle (cooldown)
  - Blocage des repeats clavier tant que la touche n'est pas relachee
- Fenetre HUD unique:
  - identification explicite de la fenetre HUD
  - fermeture des doublons
- Style HUD simplifie:
  - contraste texte fort
  - suppression des effets provoquant l'impression de halo noir

## Validation qualite executee

Build:

```bash
swift build
swift build -c release --arch arm64
```

Tests unitaires/integration:

```bash
swift test
VOICESCRIBE_RUN_MLX_TESTS=1 swift test --filter AudioFeatureTests
VOICESCRIBE_RUN_ASR_TESTS=1 swift test --filter NativeEngineTests
```

Tests ASR FR/EN avec mots-cles obligatoires:

```bash
say -v Thomas "bonjour ceci est un test de transcription rapide" -o /tmp/voicescribe_fr.aiff
afconvert -f WAVE -d LEI16@16000 /tmp/voicescribe_fr.aiff /tmp/voicescribe_fr.wav
VOICESCRIBE_RUN_ASR_TESTS=1 \
VOICESCRIBE_TEST_AUDIO=/tmp/voicescribe_fr.wav \
VOICESCRIBE_EXPECT_KEYWORDS='bonjour,test' \
swift test --filter NativeEngineTests/testTranscriptionWithSampleAudio

say -v Samantha "hello this is a fast speech transcription quality check" -o /tmp/voicescribe_en.aiff
afconvert -f WAVE -d LEI16@16000 /tmp/voicescribe_en.aiff /tmp/voicescribe_en.wav
VOICESCRIBE_RUN_ASR_TESTS=1 \
VOICESCRIBE_TEST_AUDIO=/tmp/voicescribe_en.wav \
VOICESCRIBE_EXPECT_KEYWORDS='hello,transcription' \
swift test --filter NativeEngineTests/testTranscriptionWithSampleAudio
```

## Troubleshooting rapide

- Si la transcription degenerate ("AAA...", texte vide):
  - verifier le modele charge en settings: `mlx-community/Qwen3-ASR-1.7B-8bit`
  - purger le cache modele puis relancer
  - relancer les tests FR/EN ci-dessus
- Si plusieurs popups apparaissent:
  - fermer toutes les instances VoiceScribe
  - relancer la derniere build uniquement
- Si MLX GPU n'est pas actif:
  - verifier metallib et environnement GPU
  - lancer `VOICESCRIBE_RUN_MLX_TESTS=1 swift test --filter AudioFeatureTests/testMLXvsAccelerateParity`

## Fichiers cles

- `Sources/VoiceScribe/VoiceScribeApp.swift`
- `Sources/VoiceScribeCore/Utils/HotKeyManager.swift`
- `Sources/VoiceScribeCore/ML/NativeASREngine.swift`
- `Tests/VoiceScribeTests/VoiceScribeTests.swift`
- `Tests/VoiceScribeTests/NativeEngineTests.swift`
