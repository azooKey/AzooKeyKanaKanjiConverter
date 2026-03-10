//
//  DefaultStringInterpolation+CommandLineUtils.swift
//
//
//  Created by miwa on 2024/04/29.
//

import Foundation

extension DefaultStringInterpolation {
    mutating func appendInterpolation(bold value: String) {
        self.appendInterpolation("\u{1B}[1m" + value + "\u{1B}[m")
    }

    mutating func appendInterpolation(inputHighlighted value: String) {
        self.appendInterpolation("\u{1B}[30;106m" + value + "\u{1B}[m")
    }
}
