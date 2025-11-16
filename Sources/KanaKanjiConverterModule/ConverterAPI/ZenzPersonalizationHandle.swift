#if ZenzaiCoreML && canImport(CoreML)

import EfficientNGram
import Foundation

struct ZenzPersonalizationHandle: @unchecked Sendable {
    let mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode
    let base: EfficientNGram
    let personal: EfficientNGram

    var tuple: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram) {
        (self.mode, self.base, self.personal)
    }
}

#endif
