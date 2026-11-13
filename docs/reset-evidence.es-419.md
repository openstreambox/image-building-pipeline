# Evidencia de reinicios (implementación; falta validar en hardware)

En ROCK 5B y 5B+ el script de arranque reserva 1 MiB de RAM,
`0x1f000000–0x1f0fffff`, para ramoops: consola de 512 KiB y cuatro registros
de oops/panic de 128 KiB. La reserva se agrega al DT cargado antes de `booti`.
El overlay de referencia `rk3588-ramoops.dts` se compila en las pruebas;
no se debe aplicar además de la reserva del script de arranque.

Falta comprobar el mapa real de memoria, las reservas del firmware, los rangos
de carga y la conservación de RAM durante un reinicio en cada variante de RAM,
kernel y bootloader. Un corte de energía pierde la RAM. Otros modelos RK3588,
otras familias ARM y x86 quedan pendientes porque necesitan su propio mapa de
memoria y backend validado. No se cambia la política del watchdog.

Al arrancar, `ceralive-reset-evidence.service` espera los sistemas de archivos,
`/data`, pstore y udev. Solo escribe si `/data` está montado. Reemplaza al
archivador `systemd-pstore.service`, que queda enmascarado para evitar carreras.
Guarda pstore, `watchdog*/bootstatus` y los atributos de texto de causa de
reinicio disponibles en `/data/log/reset-evidence/<fecha-UTC>_<boot-id>/`.
`evidence.json` usa esquema 1; `pstore/` contiene los archivos originales.
La secuencia identifica el orden aun cuando el reloj esté desajustado.

Conserva ocho colecciones, con hasta 16 MiB y 128 archivos pstore por colección.
Los archivos son privados. Primero sincroniza datos y directorios; después
elimina los archivos pstore. Si falla el almacenamiento, conserva las fuentes.
`bootstatus` es de solo lectura y nunca se borra ni se escribe; tampoco se
modifican los atributos de causa de reinicio. No se abre `/dev/watchdog`.
Un mapa vacío significa que no hay datos disponibles, no que el reinicio fue
normal. RK3588 puede no exponer una causa de reinicio mediante sysfs.

El lector para una futura integración privilegiada con soporte o CeraUI es:

```sh
/usr/local/sbin/ceralive-reset-evidence latest
```

Imprime el JSON más reciente: código 0 si existe, 1 si falta o no puede leerse,
2 para argumentos inválidos. No recopila ni borra datos. CeraUI no cambia.
Los registros de consola serie externos siguen siendo independientes.

Falta validar con medios recuperables y consola serie independiente: reserva,
oops/panic controlado, reinicio en caliente sin panic, estado del watchdog,
causa expuesta, borrado posterior a la copia duradera, fallas de `/data` y
retención. Registrar las versiones y repetir tras cambios de kernel/bootloader.
No se accedió a placas ni se grabaron imágenes durante esta implementación.
Detalles y límites: [contrato técnico](reset-evidence.md).
