/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// HomeScreenView.swift
//
// Welcome screen that guides users through the DAT SDK registration process.
// This view is displayed when the app is not yet registered.
//

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  var viewModel: WearablesViewModel

  var body: some View {
    ZStack {
      Color.white.edgesIgnoringSafeArea(.all)

      VStack(spacing: 12) {
        Spacer()

        Image(.mediaPipeIOSIcon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 120)

        VStack(spacing: 12) {
          HomeTipItemView(
            resource: .smartGlassesIcon,
            title: "Ray-Ban Meta",
            text: "Usa la cámara de las gafas como fuente de vídeo en primera persona."
          )
          HomeTipItemView(
            resource: .soundIcon,
            title: "MediaPipe on-device",
            text: "Detecta objetos localmente con EfficientDet Lite0; los frames no salen del iPhone."
          )
          HomeTipItemView(
            resource: .walkingIcon,
            title: "Tiempo real",
            text: "Visualiza cajas, etiquetas, confianza y latencia sobre el stream en vivo."
          )
        }

        Spacer()

        VStack(spacing: 20) {
          Text("La app Meta AI se abrirá para confirmar la conexión con tus gafas.")
            .font(.system(size: 14))
            .foregroundStyle(.gray)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)

          CustomButton(
            title: viewModel.registrationState == .registering ? "Conectando..." : "Conectar mis gafas",
            style: .primary,
            isDisabled: viewModel.registrationState == .registering
          ) {
            viewModel.connectGlasses()
          }
        }
      }
      .padding(.all, 24)
    }
  }

}

struct HomeTipItemView: View {
  let resource: ImageResource
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(resource)
        .resizable()
        .renderingMode(.template)
        .foregroundStyle(.black)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, 4)
        .padding(.top, 4)

      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.black)

        Text(text)
          .font(.system(size: 15))
          .foregroundStyle(.gray)
      }
      Spacer()
    }
  }
}
