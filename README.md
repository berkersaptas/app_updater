# App Updater Flutter OTA

App Updater, Android Flutter uygulamalarına release’e bağlı Dart-only güncellemeler gönderen,
self-hosted ve Shorebird tarzı bir OTA sistemidir. iOS code push kapsam dışıdır; iOS sürümleri
App Store/TestFlight üzerinden ilerler.

Bu rehber geliştiricinin bilgisayarında hiçbir şey kurulmamış gibi, terminalin `app_updater` komutunu
nasıl tanıdığından başlar.

## 1. Terminal `app_updater` komutunu nasıl tanır?

`app_updater`, işletim sisteminin hazır bir komutu değildir. Bu repodaki Dart CLI paketinin executable
adıdır. [app_updater_cli/pubspec.yaml](app_updater_cli/pubspec.yaml) içinde şöyle tanımlanır:

```yaml
executables:
  app_updater:
```

Geliştirici CLI’yi bilgisayarına bir kere kurar:

```bash
dart pub global activate \
  --source git https://github.com/berkersaptas/app_updater.git \
  --git-path app_updater_cli
```

Bu komut public Git reposunu indirir, `app_updater_cli/bin/app_updater.dart` giriş noktasını bulur ve
global Dart executable olarak kaydeder. macOS/Linux’ta komut genellikle şuraya yerleşir:

```text
~/.pub-cache/bin/app_updater
```

Terminal yalnızca `PATH` içindeki klasörlerde komut arar. Klasör `PATH` içinde değilse Zsh için:

```bash
echo 'export PATH="$HOME/.pub-cache/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Kurulumu kontrol et:

```bash
which app_updater
app_updater --help
```

Beklenen komutlar:

```text
login
logout
init
release
patch
publish
```

`publish` eski, elle anahtar yönetilen akıştır. Yeni uygulamalar `login`, `init`, `release` ve
`patch` kullanır.

## 2. Bilgisayar ön koşulları

Flutter kendi Dart SDK’sını beraberinde getirir. Android geliştirme ortamını kontrol et:

```bash
flutter --version
dart --version
git --version
java -version
flutter doctor
```

Repo public olduğu için GitHub hesabı, erişim token'ı veya şirket içi Git yetkisi gerekmez:

```bash
git ls-remote https://github.com/berkersaptas/app_updater.git
```

App Updater API key’i, patch private key’i veya JitPack token’ı gerekmez.

CLI’yi daha sonra güncellemek için aynı `dart pub global activate` komutu tekrar çalıştırılır.

## 3. App Updater hesabına giriş

Backend çalışıyor ve geliştirici web portalından email/şifre hesabını oluşturmuş olmalıdır. Bir
makinede yalnızca bir kez giriş yapılır:

```bash
app_updater login --backend-url https://updates.example.com
```

CLI email ve şifreyi sorar. Backend 90 günlük, iptal edilebilir bir CLI token üretir. CLI bunu
macOS/Linux’ta yalnızca mevcut kullanıcının okuyabildiği `600` izinli dosyada saklar:

```text
~/.app_updater/credentials.json
```

Kontrol:

```bash
ls -l ~/.app_updater/credentials.json
```

Bundan sonraki komutlar email, şifre veya API key istemeden bu oturumu kullanır. Oturumu hem
sunucuda iptal edip hem bilgisayardan kaldırmak için:

```bash
app_updater logout
```

## 4. Flutter projesini bağlama

Geliştirici kendi Flutter uygulamasının kök klasörüne gider:

```bash
cd ~/projects/my_flutter_app
ls pubspec.yaml
```

Backend’de yeni uygulama oluşturup projeyi bağlamak için:

```bash
app_updater init \
  --create \
  --app-slug my-app-android \
  --package-name com.company.my_app
```

Uygulama portalda daha önce oluşturulduysa veya ekip arkadaşı erişim verdiyse:

```bash
app_updater init --app-slug my-app-android
```

`init` şunları yapar:

- public `app_updater.yaml` yapılandırmasını yazar;
- `app_updater` Flutter bağımlılığını ekler;
- `MainActivity` sınıfını `FlutterOtaActivity` yapar;
- standart `lib/main.dart` yapısında `AppUpdater.instance.autoUpdate()` başlangıcını ekler;
- `--create` kullanıldıysa backend’de uygulama sahibini ve RSA-3072 managed signer’ı oluşturur.

Private signing key geliştiriciye verilmez. Backend anahtarı `SIGNING_MASTER_KEY` altında
AES-256-GCM ile şifreli saklar ve yalnızca doğrulanmış patch manifestlerini imzalar.

Standart dışı `main.dart` veya Android proje yapısında CLI riskli bir tahmin yapmak yerine gerekli
manuel değişikliği açıkça bildirir.

İlk entegrasyon kontrolü:

```bash
flutter pub get
flutter analyze
flutter build apk --debug
```

## 5. İlk Google Play release’i

Örnek `pubspec.yaml` sürümü:

```yaml
version: 1.0.0+1
```

Play’e gönderilecek release’i oluştur ve App Updater’e kaydet:

```bash
app_updater release android
```

Komut:

1. `flutter build appbundle --release` ile AAB üretir.
2. Hedef ABI içindeki `libapp.so` dosyasını doğrular.
3. Release, Flutter engine, Dart sürümü, ABI, source commit ve AAB hash’ini kaydeder.
4. AAB’yi backend’de immutable patch base olarak saklar.
5. Play Console’a yüklenecek dosyanın yolunu yazdırır.

Örnek çıktı:

```text
Registered my-app-android release 1.0.0+1 (arm64-v8a).
Upload this exact artifact to Play:
.../build/app/outputs/bundle/release/app-release.aab
```

Play’e mutlaka komutun gösterdiği aynı AAB gönderilir. Backend’deki base ile market artifact’i
aynı build olur.

## 6. Dart hotfix yayınlama

Dart kodundaki hata düzeltilir fakat `pubspec.yaml` sürümü değiştirilmez:

```yaml
version: 1.0.0+1
```

Ardından:

```bash
app_updater patch android
```

CLI otomatik olarak:

1. `1.0.0+1` ve hedef ABI için kayıtlı base AAB’yi backend’den indirir.
2. Güncel kodla patch AAB üretir.
3. Base ve patch AAB içeriklerini karşılaştırır.
4. Binary diff oluşturur ve backend’e yükler.

Yalnızca Dart’ın `base/lib/<abi>/libapp.so` çıktısı ve ona ait
`BUNDLE-METADATA/.../libapp.so.sym` debug metadata dosyası değişebilir. Şunlardan biri değişirse
patch reddedilir ve yeni Play release’i istenir:

- Android manifest veya DEX;
- native/plugin kütüphaneleri;
- Android resource’ları;
- Flutter asset’leri;
- Flutter engine veya Dart SDK;
- ABI ya da build mode.

Backend release uyumunu tekrar kontrol eder, sıradaki patch numarasını verir, manifesti managed RSA
anahtarıyla imzalar ve diff’i yayınlar. Geliştirici patch numarası, manifest, API key, private key
veya base APK/AAB yolu yönetmez.

## 7. Telefonda ne olur?

Telefon Play’den gelen `1.0.0+1` release’ini çalıştırır. Uygulama açıldıktan sonra updater backend’e
release, ABI ve mevcut patch numarasıyla sorar.

Patch varsa:

1. Manifest şeması, trusted key ve RSA imzası doğrulanır.
2. Diff indirilir ve `artifact_size` kontrol edilir.
3. Kurulu APK içindeki base `libapp.so` ile diff uygulanır.
4. Oluşan nihai `libapp.so` SHA-256 değeri doğrulanır.
5. Patch sonraki açılış için atomik olarak hazırlanır.

Mevcut açılış release üzerinde devam eder. Patch bir sonraki soğuk açılışta tekrar doğrulanıp aktif
olur. Patch açılamazsa runtime last-known-good veya APK içindeki base’e döner; hatalı patch crash
loop oluşturamaz.

Gerçek cihaz doğrulaması:

```text
Cihaz: Xiaomi 2211133G, Android 16/API 36, arm64-v8a
Release: 1.0.0+1
İlk açılış: Hello v1
Patch: 2, managed RSA, 34.608 bayt binary diff
İkinci soğuk açılış: Hello v2
Runtime state: active
Steady state: OtaNoUpdateAvailable
```

## 8. Yeni market sürümüne geçiş

Geliştirici `pubspec.yaml` sürümünü artırır:

```yaml
version: 1.1.0+2
```

Sonra tekrar:

```bash
app_updater release android
```

Backend’de release hatları birbirinden bağımsız kalır:

```text
1.0.0+1
  ├── patch 1
  └── patch 2

1.1.0+2
  └── henüz patch yok
```

- Play’den güncellemeyen kullanıcılar `1.0.0+1` patch hattında kalır.
- Play’den güncelleyen kullanıcılar `1.1.0+2` hattına geçer.
- Eski release patch’i yeni release üzerinde hiçbir zaman çalışmaz.
- `1.1.0+2` için hotfix gerekirse sürüm değişmeden `app_updater patch android` çalıştırılır.

Yeni market release’inde reset, yeniden onboarding veya yeni API key gerekmez.

## Komut zinciri

Terminalde `app_updater release android` yazıldığında gerçekleşen zincir:

```text
Terminal
  ↓ PATH içinde app_updater aranır
~/.pub-cache/bin/app_updater
  ↓ global Dart executable
app_updater_cli/bin/app_updater.dart
  ↓ oturum okunur
~/.app_updater/credentials.json
  ↓ Flutter projesi okunur
pubspec.yaml + app_updater.yaml
  ↓ release AAB oluşturulur
flutter build appbundle --release
  ↓ immutable base backend’e yüklenir
/v1/cli/apps/<app-slug>/releases
```

## Günlük kullanım özeti

Makinede bir kere:

```bash
dart pub global activate \
  --source git https://github.com/berkersaptas/app_updater.git \
  --git-path app_updater_cli
app_updater login --backend-url https://updates.example.com
```

Flutter projesinde bir kere:

```bash
app_updater init --app-slug my-app-android
```

Her Play sürümünde:

```bash
app_updater release android
```

Her Dart hotfix’inde:

```bash
app_updater patch android
```

## Sistem bileşenleri ve ileri dokümanlar

- [GETTING_STARTED.md](GETTING_STARTED.md): backend’i yerelde çalıştırma ve kısa başlangıç özeti.
- [app_updater_cli/README.md](app_updater_cli/README.md): CLI seçenekleri ve legacy komutlar.
- [app_updater/README.md](app_updater/README.md): Flutter plugin API’si.
- [backend/README.md](backend/README.md): backend işletimi ve endpointler.
- [docs/google_play_compliance.md](docs/google_play_compliance.md): Google Play/Dart-only sınırı.
- [docs/architecture_and_remaining_work.md](docs/architecture_and_remaining_work.md): mimari ve
  production öncesi kalan operasyonel işler.

## Maintainer ve cihaz kabul testleri

Bu bölüm normal uygulama geliştiricisi için değildir. Repo maintainer’ları debug/provider ve rollback
senaryolarını şu betikle çalıştırabilir:

```bash
./scripts/run_device_acceptance.sh
```

Network binary-diff kabul paketi backend veritabanını sıfırlar ve test APK’sını yeniden kurar:

```bash
./scripts/run_binary_diff_acceptance.sh
```

İkinci betik `docker compose down -v` çalıştırdığı için gerçek veya paylaşılmış bir backend üzerinde
kullanılmamalıdır.

## Production sınırı

Kod ve geliştirici iş akışı gerçek cihazda doğrulanmıştır. Fleet production için hâlâ HTTPS/reverse
proxy, durable artifact storage/CDN, managed Postgres ve yedekleme, monitoring/alerting, staged
rollout, managed signer rotation ve KMS/HSM signing custody gerekir. Bu sistem store-policy bypass
mekanizması değildir; yayıncı her uygulama ve patch’in Google Play uyumundan sorumludur.
