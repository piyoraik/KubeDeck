import Foundation
import Testing
@testable import KubeDeck

@Suite("Secret の値")
struct SecretTests {
    @Test("UTF-8 の値は復号できる")
    func decodesText() {
        #expect(SecretPlaintext.decode("cGFzc3dvcmQ=") == .text("password"))
        #expect(SecretPlaintext.decode(Data("合言葉\n".utf8).base64EncodedString()) == .text("合言葉\n"))
        #expect(SecretPlaintext.decode("") == .text(""))
    }

    @Test("UTF-8 でないものを文字列にしない")
    func binaryIsNotText() {
        let der = Data([0x30, 0x82, 0xff, 0xfe, 0x00]).base64EncodedString()
        #expect(SecretPlaintext.decode(der) == .binary)
    }

    @Test("base64 でないものを緩めて読まない")
    func invalidBase64() {
        #expect(SecretPlaintext.decode("not base64!") == .invalid)
        #expect(SecretPlaintext.decode("cGFzc3dvcmQ") == .invalid)
    }

    @Test("設定タブは平文を出さず、コピー用に原文だけ持つ")
    func digestKeepsPlaintextOffScreen() throws {
        let secret = Fixture.object(
            #"{"kind":"Secret","metadata":{"name":"s","namespace":"default"},"type":"Opaque","data":{"password":"cGFzc3dvcmQ="}}"#)
        let keys = try #require(SettingsDigest.groups(for: secret).first { $0.title == "キー" })
        let row = try #require(keys.rows.first)
        #expect(row.secretData == "cGFzc3dvcmQ=")
        #expect(row.value == "設定あり")
    }

    @Test("空の値は「設定あり」と言わない")
    func emptyValueIsCalledOut() throws {
        let secret = Fixture.object(
            #"{"kind":"Secret","metadata":{"name":"s","namespace":"default"},"data":{"a":"","b":"eA=="}}"#)
        let keys = try #require(SettingsDigest.groups(for: secret).first { $0.title == "キー" })
        #expect(keys.rows.map(\.value) == ["空", "設定あり"])
    }

    @Test("ConfigMap にはコピーの口を付けない")
    func configMapHasNoSecretData() throws {
        let map = Fixture.object(
            #"{"kind":"ConfigMap","metadata":{"name":"c","namespace":"default"},"data":{"k":"v"}}"#)
        let keys = try #require(SettingsDigest.groups(for: map).first { $0.title == "キー" })
        #expect(keys.rows.allSatisfy { $0.secretData == nil })
    }
}
