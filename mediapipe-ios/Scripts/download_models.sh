#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
model_dir="${project_dir}/mediapipe-ios/Models"
mkdir -p "${model_dir}"

download_model() {
  local filename="$1"
  local url="$2"
  local expected_sha256="$3"
  local model_path="${model_dir}/${filename}"
  local temporary_model
  local actual_sha256

  if [[ -s "${model_path}" ]]; then
    actual_sha256="$(shasum -a 256 "${model_path}" | awk '{print $1}')"
    if [[ "${actual_sha256}" == "${expected_sha256}" ]]; then
      echo "Verified MediaPipe model: ${model_path}"
      return
    fi
    echo "Replacing ${model_path}: checksum does not match the pinned model."
  fi

  temporary_model="$(mktemp "${model_path}.XXXXXX")"
  # Never leave partial downloads next to the bundled models.
  trap 'rm -f "${temporary_model}"' EXIT
  curl --fail --location --retry 3 --output "${temporary_model}" "${url}"
  actual_sha256="$(shasum -a 256 "${temporary_model}" | awk '{print $1}')"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    rm -f "${temporary_model}"
    echo "Model checksum mismatch. Expected ${expected_sha256}, got ${actual_sha256}." >&2
    exit 1
  fi

  mv "${temporary_model}" "${model_path}"
  trap - EXIT
  chmod 0644 "${model_path}"
  echo "Downloaded MediaPipe model: ${model_path}"
}

download_model \
  "efficientdet_lite0.tflite" \
  "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float32/1/efficientdet_lite0.tflite" \
  "40338edf5ec70d43e318b0a716a84d4564cd1802759a7a07170c7e43796dbf58"

download_model \
  "efficientdet_lite2.tflite" \
  "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite2/float32/1/efficientdet_lite2.tflite" \
  "ad2abbf2b4e10585e15176fd7b5ef03c28dda959ae26fc142549fdd1814db91d"

download_model \
  "efficientnet_lite0.tflite" \
  "https://storage.googleapis.com/mediapipe-models/image_classifier/efficientnet_lite0/float32/1/efficientnet_lite0.tflite" \
  "6c7ab0a6e5dcbf38a8c33b960996a55a3b4300b36a018c4545801de3a3c8bde0"

download_model \
  "selfie_segmenter.tflite" \
  "https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_segmenter/float16/1/selfie_segmenter.tflite" \
  "191ac9529ae506ee0beefa6b2c945a172dab9d07d1e802a290a4e4038226658b"

download_model \
  "magic_touch.tflite" \
  "https://storage.googleapis.com/mediapipe-models/interactive_segmenter/magic_touch/float32/1/magic_touch.tflite" \
  "e24338a717c1b7ad8d159666677ef400babb7f33b8ad60c4d96db4ecf694cd25"

download_model \
  "gesture_recognizer.task" \
  "https://storage.googleapis.com/mediapipe-models/gesture_recognizer/gesture_recognizer/float16/1/gesture_recognizer.task" \
  "97952348cf6a6a4915c2ea1496b4b37ebabc50cbbf80571435643c455f2b0482"

download_model \
  "hand_landmarker.task" \
  "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task" \
  "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1"

download_model \
  "mobilenet_v3_small.tflite" \
  "https://storage.googleapis.com/mediapipe-models/image_embedder/mobilenet_v3_small/float32/1/mobilenet_v3_small.tflite" \
  "bbbb4c51a55a53905af1daec995ca1aae355046f8839bb8c9f5ce9271394bc40"

download_model \
  "blaze_face_short_range.tflite" \
  "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite" \
  "b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f"

download_model \
  "face_landmarker.task" \
  "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task" \
  "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"

download_model \
  "pose_landmarker_lite.task" \
  "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task" \
  "59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a"

download_model \
  "holistic_landmarker.task" \
  "https://storage.googleapis.com/mediapipe-models/holistic_landmarker/holistic_landmarker/float16/1/holistic_landmarker.task" \
  "e2dab61191e2dcd0a15f943d8e3ed1dce13c82dfa597b9dd39f562975a50c3f8"
