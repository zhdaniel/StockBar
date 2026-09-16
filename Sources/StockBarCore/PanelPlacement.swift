import Foundation
import CoreGraphics


public enum PanelPlacement {
    public static func frame(anchor: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width - 16)
        let height = min(size.height, visible.height - 16)
        return CGRect(x: max(visible.minX + 8, min(anchor.midX - width / 2, visible.maxX - width - 8)),
                      y: max(visible.minY + 8, min(anchor.minY - height - 8, visible.maxY - height - 8)),
                      width: width, height: height)
    }
}
