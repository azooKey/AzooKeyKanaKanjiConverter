import Foundation

extension AncoSession {
    package init(
        defaultDictionaryRequestOptions requestOptions: ConvertRequestOptions,
        preloadDictionary: Bool = false,
        inputStyle: InputStyle = .direct,
        displayTopN: Int = 1,
        debugPossibleNexts: Bool = false,
        userDictionaryItems: [InputUserDictionaryItem] = []
    ) {
        self.init(
            converter: .withDefaultDictionary(preloadDictionary: preloadDictionary),
            requestOptions: requestOptions,
            inputStyle: inputStyle,
            displayTopN: displayTopN,
            debugPossibleNexts: debugPossibleNexts,
            userDictionaryItems: userDictionaryItems
        )
    }
}
