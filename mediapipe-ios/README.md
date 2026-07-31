# mediapipe-ios

Aplicación iOS en SwiftUI que recibe vídeo en primera persona desde unas Meta Ray-Ban mediante el Device Access Toolkit (DAT) y ejecuta las Vision Tasks de MediaPipe localmente.

## Qué incluye

- Registro y permisos mediante la app Meta AI.
- Sesión y stream de cámara con `MWDATCore` y `MWDATCamera` 0.8.0.
- Las 11 Vision Tasks on-device de `MediaPipeTasksVision` 0.10.35.
- Selector en caliente entre:
  - **EfficientDet Lite0**: menor latencia.
  - **EfficientDet Lite2**: mayor precisión.
- Menú con las 11 Vision Tasks expuestas por MediaPipe Tasks para iOS:
  Object Detection, Image Classification, Image Segmentation, Interactive Segmentation,
  Gesture Recognition, Hand Landmark Detection, Image Embedding, Face Detection,
  Face Landmark Detection, Pose Landmark Detection y Holistic Landmark Detection.
- Modelos oficiales fijados por SHA-256 para cada task.
- Cajas, máscaras, landmarks, clasificación, gestos, embeddings, latencia y contador de frames sobre el preview.
- Un único modelo activo: al cambiar de task se libera el runtime anterior antes de crear el siguiente.
- Back pressure: si MediaPipe sigue ocupado, el frame nuevo se descarta en vez de acumular trabajo.
- Captura de fotografías y soporte de `MWDATMockDevice` en Debug.

## Arquitectura

```text
Meta Ray-Ban
    │ DAT camera stream
    ▼
MWDATCamera.VideoFrame
    ├──► UIImage ──► SwiftUI preview
    └──► serial inference queue ──► MediaPipeVisionAnalyzer
                                      │ one Runtime
                                      ▼
                        boxes / masks / landmarks / text
                                      │
                                      ▼
                               SwiftUI overlay
```

`StreamSessionViewModel` coordina la sesión y el estado observable. `MediaPipeVisionAnalyzer` encapsula las Tasks, ejecuta todo en una cola serial y conserva exactamente un runtime. `DetectionGeometry` mantiene separada y comprobable la conversión entre coordenadas del modelo y el preview con `aspectFill`.

## Requisitos

- macOS con Xcode 15 o posterior.
- iOS 17 o posterior.
- CocoaPods 1.12.1 o posterior.
- Para hardware real: app Meta AI, Developer Mode y gafas compatibles.
- Para simulador: `MWDATMockDevice` incluido en Debug.

MediaPipe Tasks para iOS se distribuye oficialmente mediante CocoaPods. El enlace del MediaPipe Framework clásico usa Bazel/Tulsi; esta app usa la API Tasks precompilada para integrarse de forma mantenible con el proyecto Xcode existente.

## Preparación

Desde este directorio:

```bash
# Instala CocoaPods si aún no está disponible
brew install cocoapods

# Verifica o recupera todos los modelos oficiales fijados por SHA-256
./Scripts/download_models.sh

# Genera el workspace y resuelve MediaPipe
pod install

# Abre siempre el workspace, no el .xcodeproj
open mediapipe-ios.xcworkspace
```

Los modelos se incluyen en `mediapipe-ios/Models` para que la inferencia funcione sin red. El script solo acepta los binarios cuyos hashes coinciden con las versiones fijadas.

## Configuración de DAT

`mediapipe-ios/Info.plist` ya contiene:

- callback `mediapipe-ios://`;
- protocolo `com.meta.ar.wearable`;
- background modes de Bluetooth y external accessory;
- allowlist `fb-viewapp`;
- permisos de Bluetooth, red local, cámara y biblioteca.

Debug y Release usan `META_APP_ID = 0`, el bundle ID `com.rheadsh.mediapipe-ios` y el equipo de desarrollo disponible en esta máquina para Developer Mode. Para distribución o para otro equipo, reemplaza `META_APP_ID`, `CLIENT_TOKEN`, bundle identifier y Team ID con los valores de tu proyecto en Wearables Developer Center y Signing & Capabilities.

## Uso

1. Activa Developer Mode para las gafas en Meta AI.
2. Abre la app y pulsa **Conectar mis gafas**.
3. Con las gafas activas, pulsa **Iniciar stream y análisis**.
4. Usa el selector de modelo antes del stream o el botón `cpu` durante el stream para elegir EfficientDet Lite0 o Lite2.
5. Usa el selector **Vision task** o el botón de cuadrícula durante el stream para cambiar de task.
6. En **Interactive segmentation**, toca el objeto del preview que quieres segmentar.
7. Usa el botón de visor para pausar/reanudar MediaPipe sin detener el stream.
8. Usa el botón de cámara para capturar una foto y **Stop streaming** para terminar la sesión.

El cambio de task invalida resultados pendientes, libera el modelo anterior y prepara una sola instancia nueva en la cola de inferencia, conservando el stream DAT.

## Compilación y pruebas

```bash
xcodebuild \
  -workspace mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild test \
  -workspace mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Las pruebas cubren el stream y la fotografía con `MockDeviceKit`, la geometría del overlay y la inicialización/inferencia real de las 11 tasks, una por una.

## Rendimiento

- El stream solicita resolución baja (`360 × 640`) a 24 FPS para equilibrar Bluetooth y CPU.
- MediaPipe ejecuta una sola inferencia a la vez en una cola `userInitiated`.
- Lite0 es la opción predeterminada para tiempo real; Lite2 puede tardar más, especialmente en simulador.
- La UI recibe únicamente resultados terminados mediante `MainActor`.

## Referencias

- [MediaPipe iOS setup](https://developers.google.com/edge/mediapipe/solutions/setup_ios)
- [MediaPipe Object Detector para iOS](https://developers.google.com/edge/mediapipe/solutions/vision/object_detector/ios)
- [MediaPipe Framework para iOS](https://developers.google.com/edge/mediapipe/framework/getting_started/ios)
- [Meta Wearables DAT](https://wearables.developer.meta.com/docs/develop/)
- [Meta Wearables DAT iOS](https://github.com/facebook/meta-wearables-dat-ios)
