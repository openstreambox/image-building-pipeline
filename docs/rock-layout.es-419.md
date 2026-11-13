# Almacenamiento de ROCK 5B+

ROCK 5B+ usa dos particiones raíz de 3 GiB, una partición de arranque de 256 MiB y datos que se amplían en el primer arranque. El medio debe medir al menos 8 GiB (8589934592 bytes); una tarjeta comercial de 8 GB es insuficiente. Las actualizaciones firmadas requieren la geometría correspondiente. Cada raíz debe conservar al menos 512 MiB libres reales. La publicación requiere compilar la imagen completa y verificar arranque, datos, actualización firmada y reversión en hardware.
