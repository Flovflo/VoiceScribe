# VoiceScribe : audit macOS et modèles ASR

Revue initiale du 4 octobre 2026, sur le commit `fdc2f3f794265d79deb8c03996ef52b119afa123`. Validation poursuivie le 5 octobre.

## État du dépôt et validation initiale

Le dossier local ne contenait pas de métadonnées Git. Une copie du dépôt GitHub a été comparée fichier par fichier : aucun écart avec `main`. L'historique et le remote `origin` ont été restaurés sans remplacer les fichiers locaux. La branche de travail est `refactor/native-mlx`.

Le projet utilise déjà Swift 6 et MLX nativement. Aucun daemon Python ni lancement de sous-processus n'a été trouvé dans `Sources`. La demande concerne donc la fiabilité et la modernisation du moteur existant.

Machine de validation : Apple M3 Pro, 36 Go de mémoire, macOS 27.0, Xcode 27.1. La première compilation était bloquée par l'absence du composant Metal Toolchain. Après installation du composant officiel Xcode, `swift test` passe : **59 tests, 6 ignorés, 0 échec**. Les tests ASR réels et les tests GPU explicites font partie des tests ignorés ; ce résultat ne valide pas encore la dictée réelle. Des avertissements Metal dans MLX et des messages CoreData/XPC sont présents dans le journal.

## Constats dans le code

Ce tableau conserve les constats **avant correction**. Les corrections et les preuves de validation sont détaillées plus bas.

| Priorité | Constat | Effet possible | Localisation |
|---|---|---|---|
| Haute | Le HUD appelle `makeKeyAndOrderFront` et active VoiceScribe à l'ouverture. Le collage utilise un Cmd-V global sans conserver la cible initiale. | Le texte peut être collé dans la mauvaise application après déclenchement du raccourci. | `VoiceScribeApp.swift:315`, `AppState.swift:274`, `InputInjector.swift` |
| Haute | Le chargement peut reprendre après un `await` même si un changement de modèle ou un shutdown l'a annulé. Aucun contrôle d'annulation ou de génération ne précède la publication du modèle. | Un ancien chargement peut republier un modèle obsolète ou rétablir l'état Ready après arrêt. | `NativeASREngine.swift:115–325` |
| Haute | La boucle de génération interdit l'arrêt naturel avant huit tokens et force un token si le premier est EOS. | Du texte supplémentaire peut apparaître sur une phrase courte ou un silence, avec du calcul inutile. | `Models/Qwen3ASR.swift:154–169` |
| Haute | Le choix du microphone change le périphérique d'entrée par défaut de tout macOS. Une attente `usleep` peut bloquer le main actor jusqu'à une seconde. L'ancien périphérique n'est mémorisé qu'après cette attente. | Perturbation des autres applications audio, HUD figé, restauration absente si l'attente échoue. | `Sensors/AudioRecorder.swift:117–128`, `267–279` |
| Moyenne | `lastRMS` est écrit par le callback audio et lu par le timer UI sans verrou. | Data race malgré `@unchecked Sendable`. | `Sensors/AudioRecorder.swift:179`, `335` |
| Moyenne | `waitForFirstBuffer` ignore l'annulation de `Task.sleep`; la génération ASR ne vérifie pas non plus l'annulation. | Travail poursuivi après arrêt et démarrage d'une autre dictée. | `Sensors/AudioRecorder.swift:210`, `Models/Qwen3ASR.swift:167` |
| Moyenne | Le placement utilise la largeur et la hauteur de `visibleFrame` sans ajouter son origine. La configuration repositionne aussi un HUD déjà attaché. | Mauvais écran/position avec plusieurs écrans, déplacement de l'utilisateur perdu. | `VoiceScribeApp.swift:285–295`, `321–325` |
| Moyenne | Le task des événements garde `self` fortement pendant toute l'itération d'un flux qui ne finit jamais ; plusieurs bindings Combine retiennent aussi `AppState`. | Instances temporaires conservées et shutdown/deinit incomplets. | `NativeASRService.swift:101–106`, `AppState.swift:57–100` |
| Moyenne | MLX suit `main`; `Package.resolved` est ignoré ; `Hub` est importé sans dépendance directe déclarée dans le package Swift. | Builds non reproductibles et fragilité lors d'une évolution des dépendances. | `Package.swift`, `.gitignore`, `project.yml` |
| Moyenne | Le benchmark traite une sinusoïde, limite la génération à 16 tokens et ignore les erreurs de transcription avec `try?`. | Une transcription ratée et une phrase réelle longue ne sont pas distinguées dans la mesure. | `NativeEngineTests.swift:119–156` |
| Basse | Le HUD utilise un fond noir à 86 % ; aucune API `glassEffect` n'est présente. Les boutons d'onboarding utilisent un simple matériau translucide. | L'interface n'utilise pas encore le Liquid Glass natif demandé. | `VoiceScribeApp.swift:430`, `OnboardingComponents.swift` |
| Basse | Les libellés de taille du catalogue ressemblent à des paramètres (`0.8B`) et ne correspondent pas au téléchargement réel. | Taille et coût mémoire mal compris lors du choix du modèle. | `ASRModelCatalog.swift` |

## Comparaison ASR actuelle : français et anglais

Sources consultées le 4 octobre 2026. Les scores ci-dessous viennent des fichiers du **Open ASR Leaderboard** de Hugging Face, et non des anciens tableaux des annonces de modèles. Le WER est le pourcentage d'erreurs de mots ; plus bas est meilleur.

| Modèle | WER anglais moyen publié | FR FLEURS | FR Common Voice | FR MLS | Moyenne des 3 jeux FR¹ |
|---|---:|---:|---:|---:|---:|
| Qwen3-ASR 1.7B | 4,31 % | 4,06 % | 7,84 % | 5,15 % | 5,68 % |
| Cohere Transcribe 2B | 4,67 % | 4,33 % | 5,28 % | 2,44 % | 4,02 % |
| Parakeet TDT 0.6B v3 | 4,86 % | 4,68 % | 6,35 % | 5,12 % | 5,38 % |
| Canary 1B v2 | 5,71 % | 4,35 % | 6,58 % | 3,45 % | 4,79 % |
| Whisper large-v3 turbo | 6,36 % | 4,90 % | 11,06 % | 4,22 % | 6,73 % |
| Nemotron 3.5 ASR streaming 0.6B | 7,88 % | 9,86 % | 10,97 % | 7,36 % | 9,40 % |
| Qwen3-ASR 0.6B | 5,05 % | 7,06 % | 10,78 % | 8,44 % | 8,76 % |

¹ Moyenne arithmétique calculée ici, à poids égaux par jeu de données. Ce n'est pas une moyenne pondérée par mot, ni un score officiel bilingue. Les colonnes FR individuelles restent nécessaires pour interpréter le résultat.

Snapshots des sources :

- [Anglais, révision `0860bf2`](https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results/blob/0860bf2a924fd275ecee333545525eac8d5579cb/english_short_latest.csv), mise à jour le 1er octobre 2026.
- [Français, révision `e992776`](https://huggingface.co/datasets/hf-audio/multilingual_evals/blob/e99277674581549da40500936f934ae20a7aa1c7/multilingual_fr.csv), mise à jour le 2 octobre 2026.

Les RTFx du leaderboard mesurent un autre matériel et une autre configuration. Ils ne prouvent pas une latence sur Apple Silicon. Les scores concernent les modèles de référence, pas spécifiquement les variantes quantifiées MLX.

### Choix pour VoiceScribe

**Recommandation : garder Qwen3-ASR 1.7B comme moteur de qualité bilingue automatique pour cette passe.** Il est déjà intégré en Swift/MLX, détecte la langue et obtient le meilleur score anglais des candidats ci-dessus. Sa qualité française reste compétitive, sans être première sur tous les jeux FR.

**Cohere Transcribe 2B est le candidat à évaluer pour un mode privilégiant le français.** Il est meilleur en moyenne sur les trois jeux FR examinés, mais sa fiche exige une langue spécifiée, ne fournit pas de détection automatique explicite et signale des limites pour les phrases mélangeant plusieurs langues. Son adoption demanderait un autre moteur natif et des tests sur le même corpus. Un module Swift/MLX est annoncé par Speech Swift ; il n'est pas intégré ni validé dans VoiceScribe.

**Parakeet TDT v3 est le candidat à mesurer pour la vitesse et la consommation.** Le module natif `MLXAudioSTT` de [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/tree/main/Sources/MLXAudioSTT/Models/Parakeet) permet de l'évaluer directement en Swift/MLX, conformément à la demande. Aucune intégration CoreML ni Python n'est utilisée.

**Nemotron 3.5 est intéressant pour une future dictée en streaming**, avec ponctuation native, mais les scores actuels examinés ne justifient pas de le choisir pour la meilleure précision FR/EN. **Voxtral Realtime** est également conçu pour le streaming ; un délai de streaming annoncé à 200 ms n'est pas le temps de transcription d'un clip de dix secondes.

Références primaires : [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), [Cohere](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026), [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [Nemotron](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b), [Voxtral](https://mistral.ai/news/voxtral-transcribe-2/), [Speech Swift](https://github.com/soniqo/speech-swift).

## Mémoire et performance : limites à mesurer

L'API Hugging Face indique **1 603 081 617 octets** de poids pour [Qwen3-ASR 1.7B 4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit/tree/main), et **2 463 307 541 octets** pour [la variante 8-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/main). Ces chiffres ne comprennent pas les activations, les caches de décodage et l'interface. L'objectif de moins de 1 Go de mémoire totale ne peut donc pas être annoncé pour ces snapshots complets.

Les opérations RMSNorm et RoPE ont été remplacées par les kernels MLX fusionnés, en conservant la précision float32. Les embeddings audio sont insérés par concaténation contiguë. Quatre tests GPU de parité passent. Sur 100 exécutions évaluées, RMSNorm de forme `[1,600,2048]` passe de 0,645 à 0,301 ms ; l'insertion de 300 embeddings passe de 11,686 à 0,341 ms. Ces microbenchmarks concernent uniquement ces opérations et ne représentent pas un facteur d'accélération de la dictée complète.

Le seuil de 500 ms pour dix secondes de vraie parole reste un objectif à vérifier. Le rapport d'avril mentionnait environ 1 330 ms sur un signal synthétique avec une autre machine. Ce chiffre n'est ni une référence actuelle sur ce M3 Pro, ni une preuve de précision.

## Liquid Glass

La modernisation peut garder les flux existants : HUD flottant, Option+Espace, modèle local, sélection du microphone et collage. Les surfaces et contrôles custom doivent utiliser les APIs natives sur macOS 26+, avec un repli sur les matériaux système pour macOS 14/15. Lisibilité, réduction de transparence, réduction des animations et apparences claire/sombre doivent être vérifiées.

Apple recommande de regrouper les effets proches avec `GlassEffectContainer` pour le rendu. La présence de verre partout dans l'application ne nécessite pas d'empiler des couches de verre sur chaque texte ou chaque contenu.

Références : [adoption de Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [vues SwiftUI personnalisées](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

## Corrections et comparaison locale

- Dépendances MLX/Transformers et résolution SwiftPM verrouillées. La bibliothèque Metal empaquetée provient de la même compilation que le binaire, et les chemins SwiftPM sont détectés au lieu d'être codés en dur. Le bundle généré passe `codesign --verify --deep --strict`.
- HUD unique dans un `NSPanel` non activant : ouverture sans prendre le focus de l'application cible, position conservée et origine du moniteur secondaire prise en compte. Trois tests AppKit vérifient ces comportements.
- Chargements invalidés après changement de modèle/arrêt, caches locaux complets utilisables hors ligne, contrôle de tous les shards d'un index. Les annulations ne sont plus publiées comme erreurs par le service ASR.
- Arrêt au vrai EOS dès le premier token, respect du budget de tokens et contrôles d'annulation entre passes/chunks. Les bindings Combine et le flux d'événements ne retiennent plus leur propriétaire indéfiniment.
- Catalogue : tailles approximatives des poids en Go, distinctes du nombre de paramètres et de la mémoire totale.

Le comparatif demandé se trouve dans [`Tools/ASRBenchmark`](../Tools/ASRBenchmark/README.md). Il utilise trois processus natifs Swift/MLX séparés, les mêmes phrases FR/EN, des versions et empreintes de poids immuables, puis des variantes avec bruit, durée accrue et silence. Aucun autre backend d'inférence n'est utilisé. Les sorties brutes, erreurs, WER, temps de chargement, latences à chaud et allocations MLX sont conservés en JSON. Ce petit corpus synthétique permet une comparaison reproductible sur ce Mac ; il ne remplace pas une évaluation sur des voix humaines variées.

### Validation finale dans VoiceScribe

- `swift test` : **88 tests core + 3 tests du HUD, 8 tests optionnels ignorés, 0 échec**. Les tests optionnels ignorés sont distingués des exécutions explicites ci-dessous.
- `swift build -c release --arch arm64` : succès. La cible Xcode `VoiceScribeAppStore` compile aussi en release ; le flag de distribution est désormais propagé au framework Core, pour conserver le mode copie seule de cette variante. Les builds Xcode ne sont ni signés pour distribution ni publiés. Les builds complets des dépendances émettent des avertissements Metal C++17 amont et des avertissements d'extraction AppIntents sans dépendance ; aucune promesse globale de zéro avertissement n'est faite.
- Moteur **NativeASREngine de l'app**, Qwen 1.7B 4-bit local : transcription FR conforme aux mots-clés et sans métadonnées, transcription EN conforme aux mots-clés, puis trois répétitions EN sans sortie vide/dégénérée. Les tests utilisent les mêmes fichiers WAV du comparatif, sans indice de langue. La première transcription FR de ce processus prend 3,115 s après chargement ; la transcription EN mesurée après les répétitions prend 0,946 s, lecture WAV comprise. Ce ne sont pas les médianes du moteur externe dans le comparatif.
- Les nouvelles installations choisissent Qwen 1.7B 4-bit. Les préférences existantes restent respectées et le preset 8-bit conserve explicitement son ancien ID. Le choix réduit les poids de 2,46 à 1,60 Go ; il ne constitue pas une certification de précision sur des voix humaines.
- Capture native du micro MacBook Pro vérifiée, sortie finie à 16 kHz et périphérique macOS par défaut inchangé avant/pendant/après. Une capture AirPods Pro avait aussi passé avec AVCaptureSession ; les AirPods étaient indisponibles lors de la dernière passe incluant le teardown asynchrone, donc cette combinaison n'est pas revendiquée comme retestée.
- Le rééchantillonnage et l'arrêt matériel sont déplacés hors du main actor. Un test de non-régression reproduit deux raccourcis pendant le démarrage du micro, puis un redémarrage de dictée ; il échoue avant correction et passe après. Le shutdown d'une initialisation annulée et la libération des propriétaires sont aussi vérifiés.
- Liquid Glass natif vérifié dans les trois pages d'onboarding, les réglages avec choix avancés de modèle et le HUD prêt. Le panneau flottant nécessite un fond clair/sombre explicite sous le verre pour conserver le contraste ; la capture finale du HUD est versionnée dans `assets/readme-hud-ready.png`. Le contrôle visuel utilise un bundle de prévisualisation distinct et n'a pas modifié les préférences de l'app de production. Les trois tests du HUD passent à nouveau après cette correction.
- Cette passe visuelle couvre l'apparence sombre du Mac. Le mode clair, les options système de réduction des animations/transparence et les états HUD d'enregistrement/erreur/téléchargement n'ont pas été contrôlés visuellement. Les replis et les réglages d'accessibilité sont pris en charge dans le code, sans revendiquer une validation complète de cette matrice.
- La revue finale ajoute une coche et l'état d'accessibilité « sélectionné » aux choix de modèles, indépendamment de la teinte du verre. Le bouton de réessai prépare à nouveau un modèle non par défaut après un téléchargement interrompu ; un test reproduit le défaut avant correction puis vérifie deux appels du chargeur après correction.

Le [rapport des trois modèles](../Tools/ASRBenchmark/Results/REPORT.md) conserve les **84 générations natives MLX**. Parakeet est le plus rapide à chaud (~90/82 ms FR/EN) ; Qwen est sans erreur sur les six conditions de parole ; Voxtral prend ~15,6/19,3 s en API de clips complets. Le streaming Voxtral n'est pas évalué. La cible de 500 ms pour dix secondes de parole n'est pas certifiée pour VoiceScribe/Qwen, et aucun modèle testé ne tient sous 1 Go d'allocations MLX actives.
