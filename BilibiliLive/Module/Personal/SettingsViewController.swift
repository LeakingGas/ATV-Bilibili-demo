//
//  SettingsViewController.swift
//  BilibiliLive
//
//  Created by whw on 2022/10/19.
//

import UIKit

class SettingsViewController: UIViewController {
    class SectionModel: Hashable, Equatable {
        let title: String
        let items: [CellModel]

        init(title: String, @ArrayBuilder<CellModel> items: () -> [CellModel]) {
            self.title = title
            self.items = items()
        }

        static func == (lhs: SectionModel, rhs: SectionModel) -> Bool {
            lhs.title == rhs.title && lhs.items == rhs.items
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            hasher.combine(items)
        }
    }

    class CellModel: Hashable, Equatable {
        let title: String
        let desp: () -> String
        let action: ((@escaping () -> Void) -> Void)?

        var updateAction: (() -> Void)?

        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
        }

        static func == (lhs: CellModel, rhs: CellModel) -> Bool {
            lhs.title == rhs.title
        }

        init(title: String, desp: @autoclosure @escaping () -> String, action: ((@escaping () -> Void) -> Void)?) {
            self.title = title
            self.desp = desp
            self.action = action
        }
    }

    let collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { sectionIndex, environment -> NSCollectionLayoutSection? in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(62))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(62))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            group.interItemSpacing = .fixed(8)

            let section = NSCollectionLayoutSection(group: group)
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(44)
            )

            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: "header",
                alignment: .top
            )
            header.pinToVisibleBounds = false
            section.boundarySupplementaryItems = [header]
            section.interGroupSpacing = 8
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 18, trailing: 0)
            return section
        }
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    var dataSource: UICollectionViewDiffableDataSource<SectionModel, CellModel>!
    /// 投屏一行：右侧显示实时状态，页面打开时每 2 秒刷新。
    private var dlnaCell: CellModel?
    private var statusTimer: Timer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.dlnaCell?.updateAction?()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func makeDLNACell() -> CellModel {
        let cell = CellModel(title: "投屏（DLNA）", desp: BiliBiliUpnpDMR.shared.statusText) { update in
            Settings.enableDLNA.toggle()
            BiliBiliUpnpDMR.shared.start()
            update()
        }
        dlnaCell = cell
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(collectionView)
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.clipsToBounds = false
        // 居中、限制宽度，像 Apple TV 系统设置那样的一列。
        collectionView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().offset(-200).priority(.high)
            make.width.lessThanOrEqualTo(1180)
        }

        collectionView.delegate = self
        collectionView.register(SettingsSwitchCell.self, forCellWithReuseIdentifier: String(describing: SettingsSwitchCell.self))
        collectionView.register(SettingsHeaderView.self, forSupplementaryViewOfKind: "header", withReuseIdentifier: "HeaderView")

        configureDataSource()
        setupData()
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<SectionModel, CellModel>(collectionView: collectionView) { collectionView, indexPath, cellModel -> UICollectionViewCell? in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: SettingsSwitchCell.self), for: indexPath) as! SettingsSwitchCell
            cell.set(with: cellModel)
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "HeaderView", for: indexPath) as! SettingsHeaderView
            let title = self?.dataSource.snapshot().sectionIdentifiers[indexPath.section].title ?? UUID().uuidString

            header.label.text = title
            return header
        }
    }

    private func setupData() {
        createSnapshot {
            SectionModel(title: "账号") {
                Navigation(title: "切换账号", desp: AccountManager.shared.activeAccount?.profile.username ?? "") { [weak self] in
                    let controller = AccountSwitcherViewController()
                    controller.modalPresentationStyle = .overFullScreen
                    self?.present(controller, animated: true)
                }
                Navigation(title: "退出登录", desp: "") { [weak self] in
                    self?.confirmLogout()
                }
            }

            SectionModel(title: "首页与推荐") {
                Navigation(title: "侧边栏菜单", desp: "") { [weak self] in
                    let controller = TabBarCustomizationViewController()
                    self?.present(controller, animated: true)
                }
                Actions(title: "每行视频数", message: "重启app生效",
                        current: Settings.displayStyle.desp,
                        options: FeedDisplayStyle.allCases.filter({ !$0.hideInSetting }),
                        optionString: FeedDisplayStyle.allCases.filter({ !$0.hideInSetting }).map({ $0.desp }))
                {
                    Settings.displayStyle = $0
                }
                Actions(title: "推荐来源", message: RecommendSource.allCases.map { "\($0.title)：\($0.detail)" }.joined(separator: "\n"),
                        current: Settings.recommendSource.title,
                        options: RecommendSource.allCases,
                        optionString: RecommendSource.allCases.map { $0.title })
                {
                    Settings.recommendSource = $0
                }
                Toggle(title: "热门个性化推荐", setting: Settings.requestHotWithoutCookie, onChange: Settings.requestHotWithoutCookie.toggle())
                Toggle(title: "沉浸式浏览",
                       setting: Settings.recommendFeedFlowEnabled,
                       onChange: Settings.recommendFeedFlowEnabled.toggle())
                Actions(title: "沉浸式时长上限", message: "用于筛选沉浸式推荐中的短视频",
                        current: Settings.featuredDurationLimit.title,
                        options: FeaturedDurationLimit.allCases,
                        optionString: FeaturedDurationLimit.allCases.map { $0.title })
                {
                    Settings.featuredDurationLimit = $0
                }
                Toggle(title: "沉浸式内容过滤",
                       setting: Settings.featuredContentSafetyFilterEnabled,
                       onChange: Settings.featuredContentSafetyFilterEnabled.toggle())
                Toggle(title: "关注页刷视频模式",
                       setting: Settings.followsFeedFlowEnabled,
                       onChange: Settings.followsFeedFlowEnabled.toggle())
                { _ in
                    NotificationCenter.default.post(name: .followsLayoutModeDidChange, object: nil)
                }
            }

            SectionModel(title: "播放") {
                if VideoPlayerViewModel.vlcModeEnabled {
                Actions(title: "播放器", message: "VLC 起播更快；杜比视界只能用系统播放器。「自动」：会播杜比视界时用系统播放器，其余用 VLC",
                        current: Settings.playerEngine.title,
                        options: PlayerEngineChoice.allCases,
                        optionString: PlayerEngineChoice.allCases.map({ $0.title }))
                {
                    Settings.playerEngine = $0
                }
                }
                Actions(title: "最高画质", message: "4k以上需要大会员",
                        current: Settings.mediaQuality.desp,
                        options: MediaQualityEnum.allCases,
                        optionString: MediaQualityEnum.allCases.map({ $0.desp }))
                {
                    Settings.mediaQuality = $0
                }
                Toggle(title: "优先 AVC 编码", setting: Settings.preferAvc, onChange: Settings.preferAvc.toggle())
                Actions(title: "默认倍速", message: "默认设置为1.0",
                        current: Settings.mediaPlayerSpeed.name,
                        options: PlaySpeed.blDefaults,
                        optionString: PlaySpeed.blDefaults.map({ $0.name }))
                {
                    Settings.mediaPlayerSpeed = $0
                }
                Toggle(title: "从上次位置继续", setting: Settings.continuePlay, onChange: Settings.continuePlay.toggle())
                Toggle(title: "进入时询问续播", setting: Settings.resumePrompt, onChange: Settings.resumePrompt.toggle())
                Toggle(title: "自动连播", setting: Settings.continouslyPlay, onChange: Settings.continouslyPlay.toggle())
                Toggle(title: "跳过片头片尾", setting: Settings.autoSkip, onChange: Settings.autoSkip.toggle())
                Actions(title: "空降助手", message: "SponsorBlock：跳过视频里的广告、赞助片段",
                        current: Settings.enableSponsorBlock.title,
                        options: SponsorBlockType.allCases,
                        optionString: SponsorBlockType.allCases.map({ $0.title }))
                {
                    Settings.enableSponsorBlock = $0
                }
            }

            SectionModel(title: "画面与声音") {
                Toggle(title: "无损音频与全景声", setting: Settings.losslessAudio, onChange: Settings.losslessAudio.toggle())
                Toggle(title: "自动匹配帧率和动态范围", setting: Settings.contentMatch, onChange: Settings.contentMatch.toggle())
                Toggle(title: "仅 HDR 视频匹配", setting: Settings.contentMatchOnlyInHDR, onChange: Settings.contentMatchOnlyInHDR.toggle())
            }

            SectionModel(title: "弹幕") {
                Toggle(title: "自定义屏蔽", setting: Settings.enableDanmuFilter, onChange: Settings.enableDanmuFilter.toggle()) {
                    enable in
                    if enable {
                        Task {
                            let toast = await VideoDanmuFilter.shared.update()
                            let alert = UIAlertController(title: "同步结果", message: toast, preferredStyle: .alert)
                            alert.addAction(.init(title: "Ok", style: .cancel))
                            self.present(alert, animated: true)
                        }
                    }
                }
                Toggle(title: "移除重复弹幕", setting: Settings.enableDanmuRemoveDup, onChange: Settings.enableDanmuRemoveDup.toggle())
                Actions(title: "字号", message: "默认为36", current: Settings.danmuSize.title, options: DanmuSize.allCases, optionString: DanmuSize.allCases.map({ $0.title })) {
                    Settings.danmuSize = $0
                }
                Actions(title: "显示区域", message: "设置弹幕显示区域",
                        current: Settings.danmuArea.title,
                        options: DanmuArea.allCases,
                        optionString: DanmuArea.allCases.map({ $0.title }))
                {
                    Settings.danmuArea = $0
                }
                Actions(title: "透明度", message: "调整弹幕的透明度",
                        current: Settings.danmuAlpha.title,
                        options: DanmuAlpha.allCases,
                        optionString: DanmuAlpha.allCases.map({ $0.title }))
                { value in
                    Settings.danmuAlpha = value
                }
                Actions(title: "描边粗细", message: "调整弹幕描边的粗细",
                        current: Settings.danmuStrokeWidth.title,
                        options: DanmuStrokeWidth.allCases,
                        optionString: DanmuStrokeWidth.allCases.map({ $0.title }))
                { value in
                    Settings.danmuStrokeWidth = value
                }
                Actions(title: "描边透明度", message: "调整弹幕描边的透明度",
                        current: Settings.danmuStrokeAlpha.title,
                        options: DanmuStrokeAlpha.allCases,
                        optionString: DanmuStrokeAlpha.allCases.map({ $0.title }))
                { value in
                    Settings.danmuStrokeAlpha = value
                }
                Toggle(title: "智能防挡", setting: Settings.danmuMask, onChange: Settings.danmuMask.toggle())
                Toggle(title: "本地防挡（实验）", setting: Settings.vnMask, onChange: Settings.vnMask.toggle())
            }

            SectionModel(title: "网络加速") {
                Actions(title: "加速节点", message: "同一视频地址分发到多个CDN节点并行下载；海外用户选海外节点",
                        current: Settings.btrNodeRegion.title,
                        options: BTRNodeRegion.allCases,
                        optionString: BTRNodeRegion.allCases.map({ $0.title }))
                {
                    Settings.btrNodeRegion = $0
                }
                Toggle(title: "边下边播", setting: Settings.playWithoutWaiting, onChange: Settings.playWithoutWaiting.toggle())
            }

            SectionModel(title: "其他") {
                makeDLNACell()
                // 港澳台解锁的开关和解析服务器不在设置里显示（绕开地区版权限制，公开仓库不提供入口）。代码保留，默认关闭。
            }

            SectionModel(title: "诊断") {
                Navigation(title: "运行日志", desp: "导出") { [weak self] in
                    guard let self else { return }
                    Diag.presentExport(from: self)
                }
                Navigation(title: "下载过程记录", desp: "记录 / 导出") { [weak self] in
                    self?.showBTRTraceMenu()
                }
                Navigation(title: "投屏日志", desp: "导出") { [weak self] in
                    guard let self else { return }
                    Diag.presentDLNAExport(from: self)
                }
                Actions(title: "导出地址", message: "固定：每次都是 http://电视IP:8765/diag，可以在电脑上存书签（同一网络的人知道地址也能打开）。\n随机：每次换端口和路径，别人猜不到。",
                        current: Settings.fixedExportAddress ? "固定" : "随机",
                        options: [true, false],
                        optionString: ["固定", "随机"])
                {
                    Settings.fixedExportAddress = $0
                    BTRTraceExport.shared.stop()
                }
            }
        }
    }

    func Toggle(title: String, setting: @autoclosure @escaping () -> Bool,
                onChange: @autoclosure @escaping () -> Void,
                extraAction: ((Bool) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: setting() ? "开" : "关") {
            update in
            onChange()
            extraAction?(setting())
            update()
        }
    }

    func Actions<T>(title: String,
                    message: String?,
                    current: @autoclosure @escaping () -> String,
                    options: [T],
                    optionString: [String],
                    onSelect: ((T) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: current()) { [weak self] update in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)

            for (idx, string) in optionString.enumerated() {
                let action = UIAlertAction(title: string, style: .default) { _ in
                    onSelect?(options[idx])
                    update()
                }
                alert.addAction(action)
            }
            let cancelAction = UIAlertAction(title: nil, style: .cancel)
            alert.addAction(cancelAction)
            self?.present(alert, animated: true)
        }
    }

    func TextField(title: String,
                   message: String?,
                   current: String,
                   placeholder: String?,
                   isSecureTextEntry: Bool = false,
                   onSubmit: ((String?) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: current) { [weak self] update in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = current
                textField.keyboardType = .URL
                textField.placeholder = placeholder
                textField.isSecureTextEntry = isSecureTextEntry
            }

            let action = UIAlertAction(title: "确定", style: .default) { _ in
                onSubmit?(alert.textFields![0].text)
                update()
            }
            alert.addAction(action)

            let cancelAction = UIAlertAction(title: nil, style: .cancel)
            alert.addAction(cancelAction)
            self?.present(alert, animated: true)
        }
    }

    private func confirmLogout() {
        let alert = UIAlertController(title: "确定登出？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            WebRequest.logout {
                ApiRequest.logout { hasRemainingAccount in
                    if hasRemainingAccount {
                        AccountManager.shared.refreshActiveAccountProfile()
                    } else {
                        AppDelegate.shared.showLogin()
                    }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func Navigation(title: String,
                    desp: @autoclosure @escaping () -> String,
                    onSelect: (() -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: desp()) { update in
            onSelect?()
            update()
        }
    }
}

extension SettingsViewController: UICollectionViewDelegate {
    private func createSnapshot(@ArrayBuilder<SectionModel> builder: () -> [SectionModel]) {
        var snapshot = NSDiffableDataSourceSnapshot<SectionModel, CellModel>()
        for section in builder() {
            snapshot.appendSections([section])
            snapshot.appendItems(section.items, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let cellModel = dataSource.itemIdentifier(for: indexPath)!
        cellModel.action?() { [weak cellModel] in
            cellModel?.updateAction?()
        }
    }
}

class SettingsSwitchCell: BLMotionCollectionViewCell {
    private let titleLabel = UILabel()
    private let descLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(with model: SettingsViewController.CellModel) {
        titleLabel.text = model.title
        descLabel.text = model.desp()
        model.updateAction = { [weak self] in
            self?.descLabel.text = model.desp()
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.updateColor() }
    }

    func setupView() {
        scaleFactor = 1.02
        contentView.addSubview(titleLabel)
        contentView.addSubview(descLabel)
        // 毛玻璃风格的圆角行：平时淡白底，焦点白底黑字。
        contentView.layer.cornerRadius = 18
        contentView.layer.cornerCurve = .continuous
        titleLabel.font = .systemFont(ofSize: 24, weight: .regular)
        descLabel.font = .systemFont(ofSize: 22, weight: .regular)

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(28)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(descLabel.snp.leading).offset(-16)
        }

        descLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-28)
            make.centerY.equalToSuperview()
        }

        descLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        updateColor()
    }

    func updateColor() {
        if isFocused {
            contentView.backgroundColor = UIColor.white
            titleLabel.textColor = UIColor.black
            descLabel.textColor = UIColor.black.withAlphaComponent(0.6)
        } else {
            contentView.backgroundColor = UIColor.white.withAlphaComponent(0.07)
            titleLabel.textColor = UIColor.white.withAlphaComponent(0.92)
            descLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        }
    }
}

class SettingsHeaderView: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup() {
        addSubview(label)
        label.font = .systemFont(ofSize: 21, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(28)
            make.top.equalToSuperview().offset(22)
            make.bottom.equalToSuperview().offset(-12)
        }
    }
}

extension FeedDisplayStyle {
    var desp: String {
        switch self {
        case .large:
            return "3个"
        case .normal:
            return "4个"
        case .sideBar:
            return "-"
        }
    }
}


extension SettingsViewController {
    private func showBTRTraceMenu() {
        let exporter = BTRTraceExport.shared
        let message = exporter.address.map { "当前下载地址：\n" + $0 + "\n下载会冻结记录。请让应用保持前台。" }
            ?? "先开始记录，再播放同一视频：1080 播放后切换 4K，卡住约 15 秒后返回这里冻结导出。最多记录 10 分钟，不记录账号、签名链接或视频内容。"
        let alert = UIAlertController(title:"下载过程记录",message:message,preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"开始新记录（清空旧记录）",style:.default) { [weak self] _ in
            do { _ = try exporter.start(); self?.showBTRTraceMenu() }
            catch {
                let failed = UIAlertController(title:"无法启动日志下载",message:"本地服务启动失败，错误码：\((error as NSError).code)",preferredStyle:.alert)
                failed.addAction(UIAlertAction(title:"确定",style:.cancel))
                self?.present(failed,animated:true)
            }
        })
        if exporter.address != nil {
            alert.addAction(UIAlertAction(title:"冻结记录并显示下载地址",style:.default) { [weak self] _ in
                BTRTrace.shared.freeze()
                let result = LogExportViewController(title: "下载过程记录", address: exporter.address ?? "",
                                                     hint: "用手机扫码（或在同一网络的电脑浏览器输入地址）下载文件后发到聊天。保持本应用前台，下载完再关闭日志服务。")
                self?.present(result, animated: true)
            })
            alert.addAction(UIAlertAction(title:"关闭日志下载服务",style:.default) { _ in exporter.stop() })
        }
        alert.addAction(UIAlertAction(title:"返回",style:.cancel))
        present(alert,animated:true)
    }
}
