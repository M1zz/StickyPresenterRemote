import Combine
import Foundation
import LeeoKit
import StoreKit

// MARK: - Remote Controller Pro
//
// 칸은 둘이다: 무료 · Pro.
//
// **발표를 넘기는 조작은 언제나 무료다.** 연결 · 시작 · 멈춤 · 30초 조정 · 초기화 · 새 타이머 ·
// Siri · 단축어 · 감추기 · 정렬 · 지우기는 잠그지 않는다. 연단에서 타이머를 못 멈추게 하면
// 그건 파는 게 아니라 발표를 망치는 것이다.
// Pro 는 그 위에 얹는 것만 판다: 타이머 창 꾸미기(크기 · 테마), 끌어서 옮기기, Apple Watch.
//
// ⚠️ 스토어에서 Pro 상품을 **한 번도** 불러온 적이 없는 기기는 잠그지 않는다(`allows`).
//    App Store Connect 에 상품을 만들기 전에 빌드가 나가도, 살 수 없는데 막히는 사람이 없게.
//
// ⚠️ 페이월 전부터 쓰던 사람은 Pro 평생이다(`RemoteLegacy`). 1.1.0 까지 Apple Watch · 위치 판 ·
//    크기 조절은 무료였다. 이미 쓰던 것을 빼앗아 팔지 않는다.

/// Pro 에서 열리는 것. 페이월 비교표와 잠금 안내가 이 목록 하나를 읽는다.
enum RemoteProFeature: String, CaseIterable, Identifiable {
    /// 타이머 창 크기(S · M · L)와 테마
    case appearance
    /// 위치 판을 끌어 Mac 의 타이머 창 옮기기 (여러 화면 사이로도)
    case position
    /// Apple Watch: 남은 시간 · 5분/1분/끝 손목 진동 · 손목 조작
    case watch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: String(localized: "타이머 창 크기 · 테마")
        case .position:   String(localized: "끌어서 옮기기 · 다른 화면으로")
        case .watch:      String(localized: "Apple Watch 남은 시간 · 손목 진동")
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .position:   "hand.draw"
        case .watch:      "applewatch.radiowaves.left.and.right"
        }
    }
}

enum RemoteProducts {
    private static let prefix = "com.leeo.StickyPresenter.Remote.pro"

    // ⚠️ App Store Connect · Config/RemoteProducts.storekit 과 글자 하나까지 같아야 한다.
    //    구독 셋은 한 구독 그룹("Remote Controller Pro")에 넣는다.
    static let yearly = "\(prefix).yearly"
    static let monthly = "\(prefix).monthly"
    static let weekly = "\(prefix).weekly"
    /// 평생 (비소모성)
    static let lifetime = "\(prefix).lifetime"
    /// 구독 졸업: 구독 중인 사람만 보는 평생가 (비소모성, `LeeoGraduation`). 열면 평생과 같다.
    static let graduate = "\(prefix).graduate"

    /// 페이월이 불러올 상품. 연 구독이 기본이다.
    /// ⚠️ 팁 상품은 넣지 않는다 — 넣으면 팁을 낸 사람이 Pro 가 된다.
    static let all = [yearly, lifetime, monthly, weekly, graduate]

    /// 구독 졸업을 제안할 구독. 주 · 월 구독에 졸업가를 주면 한 주 값으로 평생이 싸지므로 연만.
    static let graduationSubscriptions: Set<String> = [yearly]
}

@MainActor
final class RemotePro: ObservableObject {
    static let shared = RemotePro()

    let store: LeeoStore

    /// 지금 살아 있는 연 구독. 있으면 설정에 '평생으로 바꾸기' 가 서고, 때가 되면 졸업가를 보인다.
    @Published private(set) var subscription: LeeoGraduation.Subscription?

    /// 잠긴 조작을 눌러 띄운 페이월. 루트 화면이 시트로 띄운다.
    @Published var paywall: RemoteProFeature?

    /// 이 기기가 스토어에서 Pro 상품을 한 번이라도 받아 봤는가.
    /// 네트워크가 잠깐 끊겨 못 불러온 것과 "아직 상품이 없다" 를 가르는 기준이다.
    @Published private(set) var hasSeenProducts: Bool
    private static let seenKey = "remote.pro.productsSeen"

    private var observation: AnyCancellable?

    private init() {
        guard let config = RemoteSpec.paywall else {
            preconditionFailure("RemoteSpec.monetization 에 페이월이 없다")
        }
        store = LeeoStore(config: config, grandfather: { await RemoteLegacy.isLegacyInstall() })
        hasSeenProducts = UserDefaults.standard.bool(forKey: Self.seenKey)
        // 스토어의 변화(구매 · 환불 · 만료 · 상품 도착)를 이 객체를 보는 화면에 그대로 흘린다.
        observation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor in self?.noteProducts() }
        }
    }

    var hasPro: Bool { store.hasPro }

    /// 이 기능을 지금 써도 되는가.
    func allows(_ feature: RemoteProFeature) -> Bool { hasPro || !hasSeenProducts }

    /// 잠겨 있으면 페이월을 띄우고 false.
    func check(_ feature: RemoteProFeature) -> Bool {
        if allows(feature) { return true }
        paywall = feature
        return false
    }

    func product(_ id: String) -> Product? { store.products.first { $0.id == id } }

    /// 앱이 켜지고 앞으로 나올 때마다 영수증을 다시 읽는다.
    func refresh() async {
        await store.refreshEntitlements()
        await store.loadProducts()
        noteProducts()
        subscription = await LeeoGraduation.currentSubscription(among: RemoteProducts.graduationSubscriptions)
    }

    /// 산 뒤 · 졸업가를 산 뒤.
    func didPurchase() async {
        await store.refreshEntitlements()
        subscription = await LeeoGraduation.currentSubscription(among: RemoteProducts.graduationSubscriptions)
    }

    /// 구독 졸업을 제안할 때인가 (6개월째 · 갱신 7일 전에 한 번씩).
    var graduationIsDue: Bool {
        guard let subscription, product(RemoteProducts.graduate) != nil else { return false }
        return LeeoGraduation.isDue(subscription, lastOffered: LeeoGraduation.lastOffered())
    }

    private func noteProducts() {
        guard !hasSeenProducts, !store.products.isEmpty else { return }
        hasSeenProducts = true
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }
}

// MARK: - 먼저 써 준 사람

/// 페이월이 생기기 전에 이 앱을 쓰던 사람인가. 맞으면 Pro 평생이다(`LeeoStore` 의 grandfather).
enum RemoteLegacy {
    /// 페이월 없는 마지막 출시 빌드: 1.1.0 빌드 9.
    /// 근거: 태그 deploy-StickyPresenterRemote-1.1.0-9 (커밋 fca42c7 "1.1.0 빌드 9 — DeployBar 배포분") 다음 커밋
    /// 3a7ba80 에서 페이월이 들어왔다. 그 전 출시 빌드는 1.0 빌드 2 · 1.0.7 빌드 3 · 1.0.8 빌드 1 · 1.0.9~1.0.12 빌드 4~8 로
    /// 모두 9 이하다. iOS 의 `originalAppVersion` 은 처음 받은 빌드의 CFBundleVersion(빌드 번호) 문자열이다.
    /// ⚠️ 그래서 이제부터 빌드 번호는 9 이하로 되돌리면 안 된다 (Config/Version.xcconfig).
    static let lastFreeBuild = 9

    private static let checkedKey = "remote.legacy.checked"
    private static let deviceKey = "remote.legacy.device"

    /// 페이월이 생긴 빌드를 **처음 켤 때 한 번만**, 리모컨이 무엇이든 기기에 적기 전에 부른다.
    /// 그때 이미 리모컨 기록(리모컨 ID · 짝 맺은 Mac · 첫 안내를 본 표시)이 있었으면 쓰던 사람이다.
    /// 오프라인이라 영수증(`AppTransaction`)을 못 읽어도 쓰던 사람이 잠기지 않게 하는 두 번째 끈이다.
    /// 리모컨 ID 는 1.0.8 부터 첫 실행마다 생겼으므로 그 뒤로 켜 본 기기는 모두 여기서 걸린다.
    static func noteFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: checkedKey) else { return }
        defaults.set(true, forKey: checkedKey)
        let hadRecords = ["remote.remoteID", "remote.pairedHostID", "hasSeenOnboarding"]
            .contains { defaults.object(forKey: $0) != nil }
        if hadRecords { defaults.set(true, forKey: deviceKey) }
    }

    /// ① 이 기기에 페이월 전부터 리모컨 기록이 있었다 (`noteFirstLaunch`).
    /// ② 이 Apple 계정이 `lastFreeBuild` 이하 빌드로 앱을 처음 받았다 — 새 기기에서도 이어진다.
    /// ⚠️ 샌드박스 · TestFlight 의 `originalAppVersion` 은 늘 "1.0" 이라 출시 환경에서만 ②를 본다.
    @MainActor
    static func isLegacyInstall() async -> Bool {
        if UserDefaults.standard.bool(forKey: deviceKey) { return true }
        guard case .verified(let app)? = try? await AppTransaction.shared,
              app.environment == .production,
              let build = Int(app.originalAppVersion) else { return false }
        return build <= lastFreeBuild
    }
}
