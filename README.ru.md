# Ядро Орион-128 для Karabas Go / Mini / Mini G

Ядро советского домашнего компьютера Орион-128 и его модификаций для плат семейства Karabas Go (Xilinx Spartan-6 XC6SLX25).

Что работает:

- процессоры КР580ВМ80А и Z80 (Z80 Card II, 2,5 / 5 / 10 МГц), ОЗУ до 1 МБ;
- видеорежимы Ориона-128, клавиатуры РК-86 и MS7007;
- ROM-диск и файлы ORDOS;
- два дисковода (`.odi`), жёсткие диски IDE (`.ohi`);
- часы платы, AY, магнитофон;
- регистры Орион-2010 и его SD-карта.

Работают OS-DOS, DSDOS 3.95 и AltairDOS / Best-DOS. Проверено на Mini G, на Go и Mini пока нет.

- [docs/GUIDE.md](docs/GUIDE.md): **как пользоваться** — что положить на SD-карту, где брать Мониторы, ROM-диски и образы дисков, что в каком порядке загружать.
- [docs/PLAN.md](docs/PLAN.md): исследование, решения, фазы.
- [docs/HARDWARE.md](docs/HARDWARE.md): поддерживаемое железо, карта памяти, порты.
- [docs/BACKLOG.md](docs/BACKLOG.md): открытые вопросы.

Готовый файл ядра `orion128.kg` выходит в [karabas-go](https://github.com/andykarpov/karabas-go), папка `cores/`.

Клонировать с `--recursive`: модули плат — подмодуль `modules/` ([karabas-go-modules](https://github.com/andykarpov/karabas-go-modules)). `src/make_core.py` ищет [karabas-go-tools](https://github.com/andykarpov/karabas-go-tools) рядом с этим репозиторием.

Лицензия ядра: GPL v3 (`LICENSE`). Сторонние части сохраняют свои лицензии и авторство в файлах: `vm80a` (CC-BY 3.0), `jt49` (GPL v3), T80 (Daniel Wallner, BSD-подобная), `wd1793` (MiSTer, Sorgelig). Мониторы и ROM-диски принадлежат их авторам.
