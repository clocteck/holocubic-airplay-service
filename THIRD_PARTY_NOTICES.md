# Third-party notices

The native module links the ESP32-S3 ALAC decoder from `espressif/esp_audio_codec` 2.5.0. Its source headers carry Espressif's modified MIT license for use on Espressif systems; this project targets ESP32-S3 hardware. The managed component and its license metadata are downloaded by the ESP-IDF component manager during the build.

AirPlay 1/RAOP interoperability uses the protocol's widely published shared AirPort Express RSA key. Protocol behavior and key encoding were cross-checked against the MIT-licensed RAOP implementation in `sle118/squeezelite-esp32` (`components/raop`). The cryptographic primitives in this directory are a new, narrow implementation for this module and do not expose a general-purpose API.

Apple, AirPlay and iPhone are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple.
