# Comparatif ASR natif MLX sur M3 Pro — 5 octobre 2026

Ces mesures exécutent trois modèles dans **Swift + MLX sur GPU**, dans un outil séparé du runtime VoiceScribe. Les trois chargements et les 84 générations ont terminé. Aucun Python ni CoreML n'a exécuté l'inférence.

Sur ce petit corpus synthétique, **Parakeet est le plus rapide**, tandis que **Qwen est le seul sans erreur de mot dans les six conditions de parole**. Voxtral produit du texte correct dans les conditions propres mais son API Swift de transcription de clips complets est beaucoup plus lente ici. Ce résultat ne mesure pas sa latence de streaming et ne constitue pas un classement universel des architectures.

Machine observée : Apple M3 Pro, 36 Gio, Version 27.0 (Build 26A5368g); build release avec Xcode 27.1 (27A9269), Apple Swift 6.4 en mode Swift 6. Les processus ont été exécutés séparément, dans l'ordre Parakeet, Qwen, Voxtral, avec réservation CPU/GPU et sans compilation ni autre inférence concurrente pendant les timings. Le cache de buffers MLX était limité à 512 Mio pour tous les modèles.

## Chargement, première inférence et mémoire

| Modèle MLX | Chargement local | Première inférence FR | Pic MLX au chargement | Pic MLX en inférence |
|---|---:|---:|---:|---:|
| parakeet | 1.643 s | 4.479 s | 3.804 Go | 1.895 Go |
| qwen | 1.184 s | 3.516 s | 1.609 Go | 2.928 Go |
| voxtral | 1.180 s | 20.692 s | 3.136 Go | 5.183 Go |

Le chargement exclut le réseau, la validation SHA256 et la lecture audio; il inclut les poids, le tokenizer et leur évaluation. Les fichiers locaux ont été lus pour valider leur SHA256 avant le chargement : le cache de pages de macOS était donc chaud. Ces chiffres ne représentent pas un démarrage après redémarrage système. La première inférence inclut les coûts de première utilisation du chemin GPU; les inférences chaudes ci-dessous ont une préparation par condition.

Les pics sont les allocations **actives MLX**, comprenant les poids résidents; ce n'est pas le RSS total. Le pic de chargement Parakeet est supérieur à son pic d'inférence, notamment pendant la conversion du stockage float32 au calcul bfloat16 par l'implémentation amont. Aucun modèle n'a tenu sous 1 Go d'allocations actives MLX dans cette comparaison.

## Latence chaude et erreurs de mots

Chaque cellule donne la médiane de trois exécutions, en millisecondes, puis le WER. Les temps comprennent les features audio, l'inférence et le décodage texte, avec synchronisation GPU; ils excluent la lecture des fichiers. WER 0 % n'affirme pas une ponctuation identique à la référence.

| Condition | Durée audio | Parakeet | Qwen | Voxtral |
|---|---:|---:|---:|---:|
| fr-clean | 8.879 s | 90.3 ms; 0.00 % | 648.4 ms; 0.00 % | 15610.0 ms; 0.00 % |
| fr-noise10dB | 8.879 s | 87.6 ms; 0.00 % | 665.2 ms; 0.00 % | 15406.5 ms; 0.00 % |
| fr-long3x | 27.638 s | 225.8 ms; 0.00 % | 1712.6 ms; 0.00 % | 53469.2 ms; 0.00 % |
| en-clean | 9.261 s | 81.6 ms; 0.00 % | 570.7 ms; 0.00 % | 19278.6 ms; 0.00 % |
| en-noise10dB | 9.261 s | 77.6 ms; 4.17 % | 567.6 ms; 0.00 % | 19063.6 ms; 4.17 % |
| en-long3x | 28.783 s | 218.7 ms; 0.00 % | 1478.4 ms; 0.00 % | 53494.2 ms; 0.00 % |
| silence10s | 10.000 s | 67.8 ms; WER non défini | 270.8 ms; WER non défini | 20038.0 ms; WER non défini |

Pour la parole propre (~9 s), Parakeet reste largement sous 500 ms après préparation; Qwen dépasse légèrement 500 ms et Voxtral prend plusieurs secondes. Les clips répétés (~28 s) exposent aussi les différences de latence. Le corpus ne contient pas un clip de parole de dix secondes exactement : aucun résultat n'est présenté comme une certification générale de la cible « < 500 ms pour 10 s ».

Parakeet et Voxtral reconnaissent « **map** » au lieu de « **Mac** » dans l'anglais à 10 dB de bruit : un remplacement parmi 24 mots, soit 4,17 % de WER. Qwen conserve « Mac ». Tous les autres cas de parole ont un WER nul. Le WER moyen non pondéré entre les six conditions de parole vaut 0,69 % pour Parakeet/Voxtral et 0 % pour Qwen. Il ne s'agit pas d'un score sur un corpus représentatif.

- parakeet sur dix secondes de silence : 0 mot émis; statut(s) ok.
- qwen sur dix secondes de silence : 0 mot émis; statut(s) ok.
- voxtral sur dix secondes de silence : 0 mot émis; statut(s) ok.

La sortie brute `status: ok` signifie que la génération a terminé sans erreur technique ni garde déclenchée, pas que la transcription est parfaite. Le WER révèle les erreurs lexicales. Le WER n'a pas de dénominateur pour le silence : le nombre de mots et le statut de hallucination sont utilisés. Le compteur `generationTokens: 0` de Parakeet est **non renseigné par l'amont**, et ne veut pas dire que le décodeur n'a généré aucun token.

## Provenance et reproductibilité

Les phrases françaises et anglaises originales ont été synthétisées le 4 octobre avec `say`, voix Thomas et Samantha, puis converties par `afconvert -f WAVE -d LEI16@16000`. Les WAV versionnés sont mono 16 kHz PCM Int16. Les variantes ajoutent un bruit blanc uniforme déterministe (seed 42) à 10 dB RMS, sans clipping/normalisation; les longs clips répètent la même phrase trois fois, avec deux pauses de 0,5 s. Les trois modèles reçoivent les mêmes fichiers, sans texte de référence dans le prompt, sans indice de langue et sans VAD.

Les IDs et révisions de poids sont immuables, avec vérification du SHA256 LFS :

- [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/tree/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15) — révision `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`, poids SHA256 `05e01c7f396c298cf7d23f61da7b504adeab698f0aaeafd9c82d198625464592`.
- [mlx-community/Qwen3-ASR-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit/tree/78a389c776a5483b2d0d4ea5494e11012e0d6159) — révision `78a389c776a5483b2d0d4ea5494e11012e0d6159`, poids SHA256 `9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45`.
- [mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit/tree/fdebf7b2af834a1db4b8a3c99ab7480b333adf9e) — révision `fdebf7b2af834a1db4b8a3c99ab7480b333adf9e`, poids SHA256 `6f59b425d8a1ceb2de795454558be63937cf75b59f9c9bc77accd85aaf32af05`.

Le code amont [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/tree/8d86630ade569728aaea3dc1a29fc44e2efa719b) est figé à `8d86630ade569728aaea3dc1a29fc44e2efa719b`; MLX-Swift est verrouillé à 0.32.3 et les dépendances transitives sont dans `Package.resolved`. L'amont a d'abord échoué en Swift 6 sur les captures non Sendable des closures compilées Parakeet. Le patch versionné `Compatibility/parakeet-swift6.patch` corrige uniquement les annotations/noms de captures pour l'usage séquentiel, sans changer les opérations du modèle. Ce problème de compilation a été corrigé avant les mesures; aucun moteur n'est déclaré « non supporté ».

Commandes de reproduction des mesures effectuées depuis la racine du dépôt, avec les snapshots déjà téléchargés :

```sh
Tools/ASRBenchmark/build.sh
BENCHMARK_BIN="$(swift build -c release --package-path Tools/ASRBenchmark --scratch-path /tmp/voicescribe-benchmark-build --show-bin-path)/asr-benchmark"
for model in parakeet qwen voxtral; do
    "$BENCHMARK_BIN" --model "$model" --model-root /tmp/voicescribe-benchmark-models --fixtures "$PWD/Tools/ASRBenchmark/Fixtures" --runs 3 --output "$PWD/Tools/ASRBenchmark/Results/$model.json"
done
```

Sur une autre machine, `"$BENCHMARK_BIN" --model all --prepare --model-root /tmp/voicescribe-benchmark-models` télécharge d'abord les snapshots épinglés. Le [guide de l'outil](../README.md) détaille les limites et les gardes : plafond 512 tokens pour Qwen/Voxtral, décodage Parakeet borné par les frames/symboles, watchdog de 180 secondes par opération. Les échecs techniques sont sauvegardés comme échecs, et un crash laisse un checkpoint incomplet.

Données intégrales, avec chaque timing, transcript, référence, statut et pic mémoire : [Parakeet](parakeet.json), [Qwen](qwen.json), [Voxtral](voxtral.json). Les trois runs contiennent chacun 28 mesures, dont 21 chaudes. Les quatre tests de WER/bruit de l'outil passent; les CLI rejettent les modèles invalides, les fixtures absentes et les poids au SHA256 incorrect.

## Limites pour une décision produit

Deux voix synthétiques, deux phrases et leurs répétitions ne prouvent pas la fiabilité sur accents humains, conversations spontanées, noms propres, français/anglais mélangés, microphones ou bruit réel. Le test n'évalue pas le streaming, les timestamps, ni l'app VoiceScribe finale. La latence Voxtral décrit cette implémentation Swift de clips complets, avec ce cache et ces réglages; une API de streaming ou d'autres optimisations doit être mesurée séparément. La méthode n'a pas instrumenté température, consommation électrique, RSS total ou activité CPU détaillée.

Ces résultats justifient d'étudier Parakeet comme option rapide et de conserver Qwen comme candidat robuste sur les cas testés. Une intégration runtime ou un choix définitif demande un corpus humain plus large et des tests dans l'app. Aucun des trois moteurs externes n'a été ajouté à la dépendance ou à l'interface de l'app par ce benchmark.
