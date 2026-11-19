# App iOS

La app recibe video de los lentes Meta Ray-Ban, ejecuta MediaPipe en el iPhone y muestra los resultados sobre la vista previa. Puedes cambiar de tarea durante la transmisión y capturar fotos.

## Instalar

Necesitas iOS 17.2 o posterior, Ruby y Bundler. El proyecto se validó con Xcode 27.1 y usa Meta Wearables DAT 1.0.1 y MediaPipeTasksVision 0.10.35.

Desde `mediapipe-ios/`, instala las dependencias y verifica los modelos incluidos por SHA-256.

```bash
bundle install
./Scripts/download_models.sh
bundle exec pod install
open mediapipe-ios.xcworkspace
```

Abre siempre el workspace para cargar MediaPipe desde CocoaPods. Selecciona el esquema `mediapipe-ios` y, para compilar en un iPhone, configura tu equipo en **Signing & Capabilities**.

## Conectar los lentes

1. Empareja los lentes en Meta AI y activa **Developer Mode**. La configuración incluida usa `META_APP_ID = 0` para este modo.
2. En la app, toca **Conectar mis lentes**, completa el registro y concede acceso a la cámara.
3. Toca **Iniciar stream y análisis** y elige una tarea. Para segmentación interactiva, toca el objeto en la vista previa.

Activa **Pantalla bloqueada** antes de iniciar si quieres mantener el análisis y OSC con el iPhone bloqueado. Este modo usa HEVC y detiene la actualización de la vista previa en segundo plano.

Para probar sin lentes, abre el menú Debug, empareja unos lentes con MockDeviceKit, enciéndelos, despliégalos, simula que los llevas puestos y configura una fuente de cámara.

## Enviar OSC

Conecta el iPhone y el receptor a la misma red. En **Configurar OSC**, introduce la IP local y el puerto del receptor, habilita **Enviar tracking por OSC** y toca **Aplicar**. Vuelve a abrir la configuración y toca **Enviar prueba /mediapipe/test**. Concede acceso a la red local si iOS lo solicita.

La app guarda el destino y la frecuencia. Debes activar el envío cada vez que abras la app. Consulta el [protocolo OSC](OSC.md) o el [ejemplo de TouchDesigner](../TouchDesigner/README.md).

## Ejecutar las pruebas

Desde `mediapipe-ios/`, elige un simulador instalado con `xcrun simctl list devices available`.

```bash
xcodebuild test -workspace mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:mediapipe-iosTests
```

Mantén la firma normal del simulador para que DAT pueda inicializarse. Para las pruebas de interfaz, usa `-only-testing:mediapipe-iosUITests`. Consulta [AGENTS.md](../AGENTS.md) para los comandos de compilación y las pautas de desarrollo.
