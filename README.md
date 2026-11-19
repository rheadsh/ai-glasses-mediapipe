# Meta Ray-Ban · MediaPipe · OSC

Una app para iPhone que analiza la cámara de los lentes Meta Ray-Ban con 11 tareas de MediaPipe. Puedes enviar los resultados por OSC a TouchDesigner u otro receptor.

- [App iOS](mediapipe-ios/README.md) para instalar, conectar los lentes y ejecutar las pruebas.
- [TouchDesigner](TouchDesigner/README.md) para probar el receptor sin lentes o integrar el componente en tu proyecto.
- [Protocolo OSC](mediapipe-ios/OSC.md) para consultar las rutas, los argumentos y las coordenadas.

El video se procesa en el iPhone. Cuando activas OSC, la app envía los resultados del análisis por UDP sin cifrado. Usa una red local de confianza.
