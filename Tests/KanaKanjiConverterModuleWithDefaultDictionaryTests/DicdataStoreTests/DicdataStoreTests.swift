//
//  DicdataStoreTests.swift
//  azooKeyTests
//
//  Created by ensan on 2023/02/09.
//  Copyright © 2023 ensan. All rights reserved.
//

@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class DicdataStoreTests: XCTestCase {
    func sequentialInput(_ composingText: inout ComposingText, sequence: String, inputStyle: KanaKanjiConverterModule.InputStyle) {
        for char in sequence {
            composingText.insertAtCursorPosition(String(char), inputStyle: inputStyle)
        }
    }

    func requestOptions() -> ConvertRequestOptions {
        .withDefaultDictionary(
            N_best: 5,
            requireJapanesePrediction: true,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            typographyLetterCandidate: false,
            unicodeCandidate: true,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            metadata: nil
        )
    }

    /// 絶対に変換できるべき候補をここに記述する
    ///  - 主に「変換できない」と報告のあった候補を追加する
    func testMustWords() throws {
        let dicdataStore = DicdataStore(convertRequestOptions: requestOptions())
        let mustWords = [
            ("アサッテ", "明後日"),
            ("オトトシ", "一昨年"),
            ("ダイヒョウ", "代表"),
            ("ヤマダ", "山田"),
            ("アイロ", "隘路"),
            ("フツカ", "二日"),
            ("フツカ", "2日"),
            ("ガデンインスイ", "我田引水"),
            ("フトウフクツ", "不撓不屈"),
            ("ナンタイ", "軟体"),
            ("ナンジ", "何時"),
            ("ナド", "等"),
            // 各50音についてチェック（辞書の破損を調べるため）
            ("アイコウ", "愛好"),
            ("インガ", "因果"),
            ("ウンケイ", "運慶"),
            ("エンセキ", "縁石"),
            ("オンネン", "怨念"),
            ("カイビャク", "開闢"),
            ("ガンゼン", "眼前"),
            ("キトク", "奇特"),
            ("ギョウコ", "凝固"),
            ("クウキョ", "空虚"),
            ("グウワ", "寓話"),
            ("ケイセイ", "形声"),
            ("ゲントウ", "厳冬"),
            ("コウシャク", "講釈"),
            ("ゴリョウ", "御陵"),
            ("サンジュツ", "算術"),
            ("ザイアク", "罪悪"),
            ("ショウシャ", "瀟洒"),
            ("ジョウドウ", "情動"),
            ("スイサイ", "水彩"),
            ("ズイイ", "随意"),
            ("センカイ", "旋回"),
            ("ゼッカ", "舌禍"),
            ("ソツイ", "訴追"),
            ("ゾウゴ", "造語"),
            ("タイコウ", "太閤"),
            ("ダツリン", "脱輪"),
            ("チンコウ", "沈降"),
            // ("ヂ")
            ("ツウショウ", "通商"),
            // ("ヅ")
            ("テンキュウ", "天球"),
            ("デンシン", "伝心"),
            ("トウキ", "投機"),
            ("ドウモウ", "獰猛"),
            ("ナイシン", "内心"),
            ("ニンショウ", "人称"),
            ("ヌマヅ", "沼津"),
            ("ネンショウ", "燃焼"),
            ("ノウリツ", "能率"),
            ("ハクタイ", "百代"),
            ("バクシン", "驀進"),
            ("パク", "朴"),
            ("ヒショウ", "飛翔"),
            ("ビクウ", "鼻腔"),
            ("ピーシー", "PC"),
            ("フウガ", "風雅"),
            ("ブンジョウ", "分譲"),
            ("プラハノハル", "プラハの春"),
            ("ヘンリョウ", "変量"),
            ("ベイカ", "米価"),
            ("ペキン", "北京"),
            ("ホウトウ", "放蕩"),
            ("ボウダイ", "膨大"),
            ("ポリブクロ", "ポリ袋"),
            ("マッタン", "末端"),
            ("ミジン", "微塵"),
            ("ムソウ", "夢想"),
            ("メンツ", "面子"),
            ("モウコウ", "猛攻"),
            ("ヤクモノ", "約物"),
            ("ユウタイ", "有袋"),
            ("ヨウラン", "揺籃"),
            ("ランショウ", "濫觴"),
            ("リンネ", "輪廻"),
            ("ルイジョウ", "累乗"),
            ("レイラク", "零落"),
            ("ロウジョウ", "楼上"),
            ("ワクセイ", "惑星"),
            ("ヲ", "を"),
        ]
        for (key, word) in mustWords {
            var c = ComposingText()
            c.insertAtCursorPosition(key, inputStyle: .direct)
            let result = dicdataStore.getLOUDSData(inputData: c, from: 0, to: c.input.endIndex - 1, needTypoCorrection: false)
            // 冗長な書き方だが、こうすることで「どの項目でエラーが発生したのか」がはっきりするため、こう書いている。
            XCTAssertEqual(result.first(where: {$0.data.word == word})?.data.word, word)
        }
    }

    /// 入っていてはおかしい候補をここに記述する
    ///  - 主に以前混入していたが取り除いた語を記述する
    func testMustNotWords() throws {
        let dicdataStore = DicdataStore(convertRequestOptions: requestOptions())
        let mustWords = [
            ("タイ", "体."),
            ("アサッテ", "明日"),
            ("チョ", "ちょwww"),
            ("シンコウホウホウ", "進行方向"),
            ("a", "あ"),   // direct入力の場合「a」で「あ」をサジェストしてはいけない
            ("\\n", "\n")
        ]
        for (key, word) in mustWords {
            var c = ComposingText()
            c.insertAtCursorPosition(key, inputStyle: .direct)
            let result = dicdataStore.getLOUDSData(inputData: c, from: 0, to: c.input.endIndex - 1, needTypoCorrection: false)
            XCTAssertNil(result.first(where: {$0.data.word == word && $0.data.ruby == key}))
        }
    }

    /// 入力誤りを確実に修正できてほしい語群
    func testMustCorrectTypo() throws {
        let dicdataStore = DicdataStore(convertRequestOptions: requestOptions())
        let mustWords = [
            ("タイカクセイ", "大学生"),
            ("シヨック", "ショック"),
            ("キヨクイン", "局員"),
            ("シヨーク", "ジョーク"),
            ("サリカニ", "ザリガニ"),
            ("ノクチヒテヨ", "野口英世"),
            ("オタノフナカ", "織田信長"),
        ]
        for (key, word) in mustWords {
            var c = ComposingText()
            c.insertAtCursorPosition(key, inputStyle: .direct)
            let result = dicdataStore.getLOUDSData(inputData: c, from: 0, to: c.input.endIndex - 1, needTypoCorrection: true)
            XCTAssertEqual(result.first(where: {$0.data.word == word})?.data.word, word)
        }
    }

    func testGetLOUDSDataInRange() throws {
        let dicdataStore = DicdataStore(convertRequestOptions: requestOptions())
        do {
            var c = ComposingText()
            c.insertAtCursorPosition("ヘンカン", inputStyle: .roman2kana)
            let result = dicdataStore.getLOUDSDataInRange(inputData: c, from: 0, toIndexRange: 2..<4)
            XCTAssertFalse(result.contains(where: {$0.data.word == "変"}))
            XCTAssertTrue(result.contains(where: {$0.data.word == "変化"}))
            XCTAssertTrue(result.contains(where: {$0.data.word == "変換"}))
        }
        do {
            var c = ComposingText()
            c.insertAtCursorPosition("ヘンカン", inputStyle: .roman2kana)
            let result = dicdataStore.getLOUDSDataInRange(inputData: c, from: 0, toIndexRange: 0..<4)
            XCTAssertTrue(result.contains(where: {$0.data.word == "変"}))
            XCTAssertTrue(result.contains(where: {$0.data.word == "変化"}))
            XCTAssertTrue(result.contains(where: {$0.data.word == "変換"}))
        }
        do {
            var c = ComposingText()
            c.insertAtCursorPosition("ツカッ", inputStyle: .roman2kana)
            let result = dicdataStore.getLOUDSDataInRange(inputData: c, from: 0, toIndexRange: 2..<3)
            XCTAssertTrue(result.contains(where: {$0.data.word == "使っ"}))
        }
        do {
            var c = ComposingText()
            c.insertAtCursorPosition("ツカッt", inputStyle: .roman2kana)
            let result = dicdataStore.getLOUDSDataInRange(inputData: c, from: 0, toIndexRange: 2..<4)
            XCTAssertTrue(result.contains(where: {$0.data.word == "使っ"}))
        }
        do {
            var c = ComposingText()
            sequentialInput(&c, sequence: "tukatt", inputStyle: .roman2kana)
            let result = dicdataStore.getLOUDSDataInRange(inputData: c, from: 0, toIndexRange: 4..<6)
            XCTAssertTrue(result.contains(where: {$0.data.word == "使っ"}))
        }
    }

    func testWiseDicdata() throws {
        let dicdataStore = DicdataStore(convertRequestOptions: requestOptions())
        do {
            var c = ComposingText()
            c.insertAtCursorPosition("999999999999", inputStyle: .roman2kana)
            let result = dicdataStore.getWiseDicdata(convertTarget: c.convertTarget, inputData: c, inputRange: 0..<12)
            XCTAssertTrue(result.contains(where: {$0.word == "999999999999"}))
            XCTAssertTrue(result.contains(where: {$0.word == "九千九百九十九億九千九百九十九万九千九百九十九"}))
        }
    }
}
