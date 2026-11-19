# Salida OSC

La app envía por UDP los resultados de la tarea seleccionada. El video se queda en el iPhone.

## Conectar el receptor

1. Conecta el iPhone y el receptor a la misma red local.
2. En **Configurar OSC**, indica la IP local del receptor, el puerto UDP (por defecto `9000`) y la frecuencia máxima (15 resultados/s por defecto, ajustable de 1 a 30).
3. Activa **Enviar tracking por OSC**, toca **Aplicar** y concede acceso a la red local.
4. Vuelve a abrir la configuración y toca **Enviar prueba /mediapipe/test**. Comprueba la recepción antes de iniciar el análisis.

La app guarda el destino y la frecuencia. Activa el envío cada vez que abras la app. En TouchDesigner puedes usar un **OSC In DAT** o el [receptor incluido](../TouchDesigner/README.md). En Max, usa un receptor OSC/UDP y enruta los mensajes por dirección.

## Formato y rutas comunes

OSC 1.0 usa enteros de 32 bits (`i`), flotantes de 32 bits (`f`) y cadenas ASCII (`s`). Los números van en orden big-endian y las cadenas terminan en nulo y se rellenan a múltiplos de 4 bytes. Los caracteres no ASCII o nulos dentro de las etiquetas se sustituyen por `?`. Cada datagrama contiene un bundle inmediato de hasta 1200 bytes.

Sustituye `<task>` por el nombre exacto de la tarea. Los índices empiezan en cero.

| Dirección | Argumentos | Uso |
|---|---|---|
| `/mediapipe/test` | `s "rayban", i 1` | Prueba el destino aplicado. |
| `/mediapipe/frame` | `i frameID` | Aparece en **cada bundle** para agrupar fragmentos del mismo resultado. |
| `/mediapipe/<task>/active` | `i active` | `1`: resultado válido; `0`: limpiar toda la tarea. |
| `/mediapipe/<task>/counts` | `i results, i detections, i groups` | Cantidades del frame actual. Un resultado vacío también se envía. |
| `/mediapipe/<task>/inferenceMs` | `f milliseconds` | Duración del análisis. |
| `/mediapipe/<task>/detection/<index>` | `s label, f score, f x, f y, f width, f height` | Caja normalizada; origen arriba a la izquierda. |
| `/mediapipe/<task>/landmarks/<group>/count` | `i count` | Número de puntos del grupo. |
| `/mediapipe/<task>/landmarks/<group>/points` | `i offset, f x0, f y0, ...` | Bloques de hasta 32 puntos; `offset` indica el índice inicial. |

Las coordenadas corresponden a la imagen de cámara antes del recorte de la vista previa. Los landmarks son 2D y pueden quedar fuera de 0…1. Los índices de grupo son locales al resultado.

## Rutas por tarea

Los sufijos de estas tablas se añaden a `/mediapipe/<task>`.

| `<task>` | Datos enviados |
|---|---|
| `objectDetection` | `/detection/<index>` para EfficientDet Lite0 o Lite2. |
| `imageClassification` | `/category/<index>`: `s category, f score`. |
| `imageSegmentation` | Máscara de confianza reducida (ver la tabla siguiente). |
| `interactiveSegmentation` | Máscara y `/selection`: `f x, f y` del punto seleccionado. También el punto en landmarks. |
| `gestureRecognition` | Landmarks de manos, `/gesture/<hand>`: `s gesture, f score`; `/hand/<hand>/handedness`: `s LeftOrRight, f score`. |
| `handLandmarkDetection` | Landmarks y `/hand/<hand>/handedness`: `s LeftOrRight, f score`. |
| `imageEmbedding` | `/embedding/dimensions`: `i count`; `/embedding/values`: `i offset, f value0, ...`, hasta 64 valores por mensaje. Vector del modelo. |
| `faceDetection` | Cajas de rostros y keypoints en grupos de landmarks. |
| `faceLandmarkDetection` | Puntos de la malla facial por grupo. |
| `poseLandmarkDetection` | Landmarks de la pose por grupo. |
| `holisticLandmarkDetection` | Grupos disponibles y `/landmarks/<group>/label`: `s face`, `pose`, `leftHand` o `rightHand`. Las etiquetas permiten distinguir grupos ausentes. |

### Máscaras

Ambas tareas de segmentación muestrean el centro de cada celda del primer canal de confianza y limitan los valores a 0…1.

| Sufijo | Argumentos | Uso |
|---|---|---|
| `/mask/size` | `i width, i height` | `16, 16` o `0, 0` si falta la máscara. |
| `/mask/row` | `i row, f c0, ... f c15` | Una fila por mensaje, 16 filas por máscara. |
| `/mask/coverage` | `f meanConfidence` | Promedio de las 256 muestras de confianza. |

## Reconstruir y limpiar el estado

- Agrupa los fragmentos por `frameID`. Usa los conteos, tamaños y offsets para reconstruir cada resultado. Descarta los frames incompletos o anteriores al último aplicado.
- Un resultado vacío conserva `active=1` y los conteos en cero. Al desactivar el análisis, cambiar de tarea o modelo, pausar o detener el stream, la app intenta enviar `active=0` con los conteos en cero. También intenta limpiar antes de cambiar el destino o apagar OSC.
- Limpia el estado si dejas de recibir frames completos durante el tiempo de espera del receptor (por ejemplo, 1 segundo). UDP puede perder o reordenar mensajes, incluida la limpieza.
- El `frameID` vuelve a empezar con cada sesión del emisor. La frecuencia real depende del análisis y la app descarta resultados si sigue ocupado el envío anterior.

[Especificación OSC 1.0](https://opensoundcontrol.stanford.edu/spec-1_0.html)
