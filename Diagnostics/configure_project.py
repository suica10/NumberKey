from pathlib import Path

project = Path('project.yml')
spec = project.read_text()
# Insert a hosted iOS test target before the root schemes key.
target = '''  KeyboardLifecycleTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Diagnostics
        includes: ['*.swift']
      - path: Keyboard
        excludes: ['Info.plist']
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: jp.suica10.NumberKey.LifecycleTests
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_FILE: ''
        # Same requirement as NumberKeyKeyboard in project.yml: this target
        # compiles the Keyboard sources and imports the converter, whose
        # chain ends in SwiftyMarisa's C++-only marisa_trie module. Without
        # C++ interoperability the Swift frontend parses its headers as C
        # and fails on 'namespace'.
        SWIFT_OBJC_INTEROP_MODE: objcxx
    dependencies:
      - target: NumberKey
      - package: Converter
        product: KanaKanjiConverterModuleWithDefaultDictionary
'''
spec = spec.replace('schemes:\n', target + 'schemes:\n', 1)
spec += '''  KeyboardStartup:
    build:
      targets:
        NumberKey: all
        KeyboardLifecycleTests: [test]
    test:
      targets: [KeyboardLifecycleTests]
'''
project.write_text(spec)
