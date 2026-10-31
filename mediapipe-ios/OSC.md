# Salida OSC para instalaciones

La app envía por UDP los resultados de la **Vision Task seleccionada**. Los modelos
se ejecutan uno a la vez, igual que en el preview. No se transmite el vídeo por OSC.
No se necesitan dependencias adicionales: el transporte usa Network.framework.

## Conexión

1. Abre `mediapipe-ios.xcworkspace` en Xcode y ejecuta la app.
2. Conecta el iPhone y el equipo receptor a la misma red local.
3. Abre **Configurar OSC** en la pantalla de streaming o antes de iniciarlo.
4. Introduce la IP del equipo receptor, el puerto UDP (por defecto `9000`) y la
   frecuencia máxima (por defecto 15 resultados/s, configurable de 1 a 30).
5. Activa **Enviar tracking por OSC** y pulsa **Aplicar**. Permite el acceso a la
   red local en iOS. Si lo denegaste, habilítalo en Ajustes de iOS para esta app.
6. Vuelve a abrir OSC y pulsa **Enviar prueba**. El receptor debe recibir
   `/mediapipe/test` con argumentos string `rayban` e int `1`.
7. Inicia el stream y selecciona una Vision Task para recibir sus resultados.

En TouchDesigner puedes usar un **OSC In DAT**, con el puerto configurado, para
recibir todos los argumentos. En Max utiliza un receptor OSC/UDP y enruta por las
direcciones indicadas abajo. Permite el tráfico UDP entrante en el firewall del
receptor. `127.0.0.1` en un iPhone apunta al propio teléfono; introduce la IP del
ordenador, no la del teléfono.

La IP, el puerto y la frecuencia se conservan. El envío queda **desactivado en cada
apertura** y se detiene al salir de la pantalla de la sesión. Abrir configuración
no activa el envío; los cambios se aplican con **Aplicar**. El botón de prueba usa
el destino ya aplicado. UDP listo/enviado significa que el sistema aceptó el envío,
no que el receptor haya confirmado su recepción.

## Protocolo común

OSC 1.0: int32 (`i`), float32 (`f`) y string ASCII (`s`), con números big-endian y
cadenas alineadas a 4 bytes. Caracteres no ASCII o nulos en etiquetas se sustituyen
por `?`. Cada datagrama es un bundle con timetag inmediato y como máximo 1200 bytes.

`<task>` es el nombre exacto de la tabla siguiente. Los índices empiezan en cero.

| Dirección | Argumentos | Uso |
|---|---|---|
| `/mediapipe/frame` | `i frameID` | Aparece en **cada bundle** para agrupar fragmentos del mismo resultado. |
| `/mediapipe/<task>/active` | `i active` | `1`: resultado válido; `0`: limpiar toda la tarea. |
| `/mediapipe/<task>/counts` | `i results, i detections, i groups` | Cantidades del frame actual. Un resultado vacío también se envía. |
| `/mediapipe/<task>/inferenceMs` | `f milliseconds` | Duración del análisis. |
| `/mediapipe/<task>/detection/<index>` | `s label, f score, f x, f y, f width, f height` | Caja normalizada; origen arriba a la izquierda. |
| `/mediapipe/<task>/landmarks/<group>/count` | `i count` | Número de puntos del grupo. |
| `/mediapipe/<task>/landmarks/<group>/points` | `i offset, f x0, f y0, ...` | Bloques de hasta 32 puntos; `offset` indica el índice inicial. |

Las coordenadas son las de la imagen de cámara, **antes del recorte aspect-fill del
preview**. Se envían los landmarks 2D que usa el overlay; no profundidad ni world
landmarks. Algunas coordenadas de landmarks pueden quedar fuera de 0…1. Los índices
de grupos corresponden al resultado del modelo de ese frame: no son IDs persistentes
de personas o manos.

## Datos por tarea

Las rutas de la columna final son relativas a `/mediapipe/<task>`.

| `<task>` | Datos enviados |
|---|---|
| `objectDetection` | `detection/<index>` para EfficientDet Lite0 o Lite2. |
| `imageClassification` | `/category/<index>`: `s category, f score`. |
| `imageSegmentation` | Máscara de confianza reducida: ver abajo. |
| `interactiveSegmentation` | Máscara y `/selection`: `f x, f y` del punto seleccionado. También el punto en landmarks. |
| `gestureRecognition` | Landmarks de manos, `/gesture/<hand>`: `s gesture, f score`; `/hand/<hand>/handedness`: `s LeftOrRight, f score`. |
| `handLandmarkDetection` | Landmarks y `/hand/<hand>/handedness`: `s LeftOrRight, f score`. |
| `imageEmbedding` | `/embedding/dimensions`: `i count`; `/embedding/values`: `i offset, f value0, ...`, hasta 64 valores por mensaje. Vector float del modelo, sin clasificarlo. |
| `faceDetection` | Cajas de rostros y keypoints en grupos de landmarks. |
| `faceLandmarkDetection` | Puntos de la malla facial por grupo. |
| `poseLandmarkDetection` | Landmarks de la pose por grupo. |
| `holisticLandmarkDetection` | Grupos disponibles y `/landmarks/<group>/label`: `s face`, `pose`, `leftHand` o `rightHand`. Las etiquetas permiten distinguir grupos ausentes. |

Segmentación envía el **primer canal** de confianza del modelo:

- `/mask/size`: `i width, i height` (`16, 16`; `0, 0` si no hay máscara).
- `/mask/row`: `i row, f c0, ... f c15`, 16 mensajes de filas por resultado.
- `/mask/coverage`: `f meanConfidence`, promedio de las 256 muestras; no es un
  porcentaje binario de área ni la máscara completa a resolución original.

El muestreo usa el centro de cada celda. La confianza se limita a 0…1.

## Estado, frecuencia y recepción

El emisor limita la frecuencia y descarta resultados mientras un envío anterior
está en curso, evitando acumular latencia. La frecuencia real depende también del
modelo y del número de frames analizados.

Al desactivar el análisis, cambiar de tarea/modelo, pausar o detener el stream, se
intenta enviar `active=0` y counts en cero para limpiar la tarea anterior. Al cambiar
de destino o apagar OSC, se intenta enviar la limpieza antes de cerrar la conexión.
Un frame sin detecciones se publica con `active=1` y counts en cero.

Como UDP puede perder o reordenar paquetes:

- Agrupa los fragmentos por `frameID`; ignora frames anteriores al último aplicado.
- Usa counts y tamaños para borrar objetos/grupos antiguos y reconstruir los arrays.
- No combines fragmentos de frames diferentes. Descarta frames incompletos.
- Añade un timeout de recepción (por ejemplo 1 segundo) para limpiar el estado si
  desaparece la app, se corta la red o se pierde el mensaje `active=0`.
- `frameID` es local a la sesión del emisor y vuelve a empezar al crearla.

Referencia del formato: [Open Sound Control 1.0](https://opensoundcontrol.stanford.edu/spec-1_0.html).
