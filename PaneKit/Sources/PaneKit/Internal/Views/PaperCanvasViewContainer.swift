import SwiftUI

struct PaperCanvasViewContainer<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: BonsplitConfiguration.Appearance
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear

                if let zoomedPaneId = controller.zoomedPaneId,
                   let placement = controller.paperCanvas?.pane(zoomedPaneId) {
                    SinglePaneWrapper(
                        pane: placement.pane,
                        contentBuilder: contentBuilder,
                        emptyPaneBuilder: emptyPaneBuilder,
                        showSplitButtons: showSplitButtons,
                        contentViewLifecycle: contentViewLifecycle
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ForEach(controller.paperCanvas?.panes ?? []) { placement in
                        SinglePaneWrapper(
                            pane: placement.pane,
                            contentBuilder: contentBuilder,
                            emptyPaneBuilder: emptyPaneBuilder,
                            showSplitButtons: showSplitButtons,
                            contentViewLifecycle: contentViewLifecycle
                        )
                        .frame(width: placement.frame.width, height: placement.frame.height)
                        .offset(
                            x: placement.frame.minX - controller.paperViewportOrigin.x,
                            y: placement.frame.minY - controller.paperViewportOrigin.y
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TabBarColors.paneBackground(for: appearance))
            .clipped()
            .focusable()
            .focusEffectDisabled()
            .onAppear {
                controller.setPaperViewportFrame(geometry.frame(in: .global))
            }
            .onChange(of: geometry.size) { _, _ in
                controller.setPaperViewportFrame(geometry.frame(in: .global))
            }
        }
    }
}
