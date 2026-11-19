# Receptor OSC para TouchDesigner

Recibe los resultados de MediaPipe y úsalos para controlar visuales, luces o sonido. El receptor se validó con TouchDesigner 2025.33230.

## Probar sin lentes

1. Abre [RayBan_MediaPipe_OSC.toe](RayBan_MediaPipe_OSC.toe).
2. Selecciona `rayban_osc` y activa **Receiver → Demo (Fake Data)**.
3. Elige `gestureRecognition` en **Demo Task** y abre el visor de `easy_example`. El círculo sigue el dedo simulado y responde al gesto y a la pinza.

## Conectar el iPhone

1. Desactiva **Demo** y conecta el iPhone y la computadora a la misma red local.
2. Usa la IP y el puerto que muestra el monitor para [configurar OSC en la app](../mediapipe-ios/README.md#enviar-osc). El puerto predeterminado es `9000`.
3. Envía la prueba y confirma que el monitor indique **PRUEBA OK**. Al iniciar el análisis debe indicar **RECIBIENDO**.

Usa un receptor por puerto. Si la prueba falla, revisa la IP, el permiso de red local del iPhone y el acceso de TouchDesigner en el firewall.

## Usar el componente y los ejemplos

Arrastra [RayBan_OSC.tox](RayBan_OSC.tox) a tu proyecto y ajusta **Receiver → UDP Port**.

| Salida | Uso |
| --- | --- |
| `controls` (CHOP) | Mapea canales como `presence`, `point_x`, `point_y`, `pinch_distance` y `gesture_*`. Elige el punto en **Outputs → Track Point**. |
| `points` (CHOP) | Usa `tx`, `ty` y `scale` para dibujar una instancia por landmark. |
| `preview` (TOP) | Muestra las cajas, los landmarks y la máscara recibidos. |

[Easy CHOPs](examples/RayBan_Easy_CHOPs.tox) usa `controls` para mover y cambiar un círculo. [Points Instancing](examples/RayBan_Points_Instancing.tox) usa `points` para dibujar una esfera por landmark.

[Finger Geometry](RayBan_Finger_Geometry.toe) dibuja cinco formas por mano. Selecciona la tarea de landmarks de mano o de reconocimiento de gestos en el iPhone. Al juntar el pulgar y el índice, se encoge el círculo turquesa. Las formas desaparecen al perder el seguimiento. Usa **View** en `TRACKING_EN_VIVO` para reabrir el monitor.

## Probar y reconstruir el receptor

Desde `TouchDesigner/`, con **Demo** desactivado, el primer comando envía datos sintéticos por UDP y el segundo ejecuta las pruebas de Python.

```bash
python3 demo/demo_sender.py --task handLandmarkDetection --seconds 30
python3 -B -m unittest discover -s dev -p 'test_*.py' -v
```

Para reconstruir el componente y los ejemplos, abre `RayBan_MediaPipe_OSC.toe` y ejecuta [build_project.py](dev/build_project.py) en el Textport.

```python
exec(open(project.folder + '/dev/build_project.py').read())
```

Consulta el [protocolo OSC](../mediapipe-ios/OSC.md) para conocer los datos de cada tarea.
