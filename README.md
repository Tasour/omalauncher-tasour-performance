# omalauncher-tasour-performance

Widget OWL de monitoring système pour [omalauncher](https://github.com/SimonSchubert/omalauncher) : batterie, CPU, RAM Android, réseau, GPU, températures, notes A à E, moyennes 5 min / 1 h / 6 h / 1 j, top des consommateurs et purge.

## Installation

```sh
cp 55-performance.owl ~/.config/omalauncher/widgets/
mkdir -p ~/.local/share/omalauncher/perf
cp scripts/android-adb.sh scripts/logger.sh ~/.local/share/omalauncher/perf/
chmod +x ~/.local/share/omalauncher/perf/*.sh
owl-check ~/.config/omalauncher/widgets/55-performance.owl
```

Dépendances : `procps-ng`, `findutils`, `util-linux`, `jq` (et `adb` pour les métriques Android via le débogage sans fil).

## Données et confidentialité

Toutes les mesures sont locales : sources `android.*` du launcher, `/proc`, fichiers de journalisation sous `~/.local/share/omalauncher/perf/` et connexion ADB à votre propre téléphone. Aucun appel réseau sortant, aucun token, aucun identifiant d'appareil codé en dur. Les journaux bruts ne sont pas versionnés.

Audit de sécurité effectué avant publication : aucune donnée personnelle ni secret bloquant.

## Licence

MIT — voir [LICENSE](LICENSE).
