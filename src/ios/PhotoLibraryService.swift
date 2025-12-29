import UIKit
import Photos
import CoreGraphics

/// 照片库服务类 - 优化版（完全基于Photos框架，无废弃API）
class PhotoLibraryService: NSObject {
    
    // MARK: - 常量定义
    private let cachingImageManager = PHCachingImageManager()
    private var cacheActive: Bool = false
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    private let thumbnailRequestOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true // 允许访问iCloud资源
        return options
    }()
    private let fullImageRequestOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return options
    }()
    // MIME类型映射表
    private let mimeTypes: [String: String] = [
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "tiff": "image/tiff",
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "avi": "video/x-msvideo",
        "flv": "video/x-flv",
        "wmv": "video/x-ms-wmv",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "aac": "audio/aac"
    ]
    
    // MARK: - 公开配置参数
    struct LibraryOptions {
        var thumbnailWidth: CGFloat = 100
        var thumbnailHeight: CGFloat = 100
        var includeImages: Bool = true
        var includeVideos: Bool = true
        var includeAudio: Bool = true
        var includeAlbumData: Bool = true
        var includeCloudAssets: Bool = true
        var chunkSize: Int = 50 // 分块大小
    }
    
    // MARK: - 生命周期
    deinit {
        // 销毁时停止缓存，释放资源
        stopCaching()
    }
    
    // MARK: - 缓存管理
    private func startCaching(for assets: [PHAsset], options: LibraryOptions) {
        guard assets.count > 0 && !cacheActive else { return }
        
        let targetSize = CGSize(width: options.thumbnailWidth, height: options.thumbnailHeight)
        // 先停止旧缓存，避免内存泄漏
        stopCaching()
        // 启动新缓存
        cachingImageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: thumbnailRequestOptions
        )
        cacheActive = true
    }
    
    private func stopCaching() {
        guard cacheActive else { return }
        cachingImageManager.stopCachingImagesForAllAssets()
        cacheActive = false
    }
    
    // MARK: - 公开方法：获取照片库资源
    /// 获取照片库资源（分块返回，保证顺序）
    /// - Parameters:
    ///   - options: 配置参数
    ///   - chunkCompletion: 分块回调
    ///   - finalCompletion: 全部完成回调
    func getLibrary(options: LibraryOptions,
                    chunkCompletion: @escaping ([Dictionary<String, Any>]) -> Void,
                    finalCompletion: @escaping (Error?) -> Void) {
        // 1. 权限检查
        checkPhotoPermission { [weak self] granted in
            guard let self = self, granted else {
                finalCompletion(NSError(domain: "PhotoLibraryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "未获取照片库访问权限"]))
                return
            }
            
            // 2. 构建查询条件
            var fetchOptions = PHFetchOptions()
            // 排序：按创建时间倒序
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            // 过滤：是否允许iCloud资源
            fetchOptions.isNetworkAccessAllowed = options.includeCloudAssets
            
            // 3. 构建媒体类型过滤
            var mediaTypes = [PHAssetMediaType]()
            if options.includeImages {
                mediaTypes.append(.image)
            }
            if options.includeVideos {
                mediaTypes.append(.video)
            }
            if options.includeAudio {
                mediaTypes.append(.audio)
            }
            guard !mediaTypes.isEmpty else {
                finalCompletion(NSError(domain: "PhotoLibraryService", code: -2, userInfo: [NSLocalizedDescriptionKey: "未选择任何媒体类型"]))
                return
            }
            fetchOptions.predicate = NSPredicate(format: "mediaType IN %@", mediaTypes)
            
            // 4. 执行查询
            let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
            guard fetchResult.count > 0 else {
                chunkCompletion([])
                finalCompletion(nil)
                return
            }
            
            // 5. 启动缓存
            let assets = fetchResult.objects(at: IndexSet(0..<fetchResult.count))
            self.startCaching(for: assets, options: options)
            
            // 6. 分块处理（使用DispatchGroup保证单块内顺序）
            let totalCount = fetchResult.count
            let totalChunks = Int(ceil(Double(totalCount) / Double(options.chunkSize)))
            
            for chunkIndex in 0..<totalChunks {
                let startIndex = chunkIndex * options.chunkSize
                let endIndex = min(startIndex + options.chunkSize, totalCount)
                let currentIndexSet = IndexSet(startIndex..<endIndex)
                let currentAssets = fetchResult.objects(at: currentIndexSet)
                
                let group = DispatchGroup()
                var chunkItems = [Dictionary<String, Any>]()
                
                for asset in currentAssets {
                    group.enter()
                    // 转换为自定义资源模型
                    self.assetToLibraryItem(asset: asset, options: options) { libraryItem in
                        if let item = libraryItem {
                            chunkItems.append(item)
                        }
                        group.leave()
                    }
                }
                
                // 单块处理完成后回调
                group.notify(queue: .main) {
                    chunkCompletion(chunkItems)
                    
                    // 最后一块处理完成后，停止缓存并回调最终完成
                    if chunkIndex == totalChunks - 1 {
                        self.stopCaching()
                        finalCompletion(nil)
                    }
                }
            }
        }
    }
    
    // MARK: - 私有方法：PHAsset转自定义LibraryItem
    private func assetToLibraryItem(asset: PHAsset,
                                    options: LibraryOptions,
                                    completion: @escaping (Dictionary<String, Any>?) -> Void) {
        // 基础信息
        var libraryItem = [String: Any]()
        libraryItem["localIdentifier"] = asset.localIdentifier
        libraryItem["mediaType"] = self.mediaTypeString(from: asset.mediaType)
        libraryItem["creationDate"] = asset.creationDate.flatMap { dateFormatter.string(from: $0) }
        libraryItem["modificationDate"] = asset.modificationDate.flatMap { dateFormatter.string(from: $0) }
        libraryItem["pixelWidth"] = asset.pixelWidth
        libraryItem["pixelHeight"] = asset.pixelHeight
        libraryItem["duration"] = asset.duration // 视频/音频时长
        libraryItem["favorite"] = asset.isFavorite
        libraryItem["hidden"] = asset.isHidden
        
        // 获取文件名和MIME类型
        self.getAssetFileNameAndMIME(asset: asset) { fileName, mimeType in
            libraryItem["filename"] = fileName
            libraryItem["mimeType"] = mimeType
            
            // 完善相册数据（TODO完成）
            if options.includeAlbumData {
                let albums = PHAssetCollection.fetchAssetCollections(
                    containing: asset,
                    type: .album,
                    subtype: .any
                )
                var albumNames = [String]()
                albums.enumerateObjects { collection, _, _ in
                    if let title = collection.localizedTitle, !title.isEmpty {
                        albumNames.append(title)
                    }
                }
                libraryItem["albums"] = albumNames
            }
            
            // 获取完整文件路径
            self.getCompleteInfo(for: asset) { fullPath in
                libraryItem["fullPath"] = fullPath
                
                // 获取缩略图
                self.getThumbnail(for: asset, options: options) { thumbnailData in
                    libraryItem["thumbnailData"] = thumbnailData
                    completion(libraryItem)
                }
            }
        }
    }
    
    // MARK: - 私有方法：获取资源缩略图
    private func getThumbnail(for asset: PHAsset,
                              options: LibraryOptions,
                              completion: @escaping (Data?) -> Void) {
        let targetSize = CGSize(width: options.thumbnailWidth, height: options.thumbnailHeight)
        guard targetSize.width > 0 && targetSize.height > 0 else {
            completion(nil)
            return
        }
        
        cachingImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: thumbnailRequestOptions
        ) { [weak self] image, _ in
            guard let self = self, let originalImage = image else {
                completion(nil)
                return
            }
            // 精确缩放图片（TODO完成：图片尺寸调整）
            let resizedImage = self.resizeImage(to: targetSize, image: originalImage)
            completion(resizedImage.pngData())
        }
    }
    
    // MARK: - 私有方法：获取资源完整路径（支持图片/视频/音频，TODO完成：音频支持）
    private func getCompleteInfo(for asset: PHAsset, completion: @escaping (String?) -> Void) {
        let mediaType = self.mediaTypeString(from: asset.mediaType)
        
        switch mediaType {
        case "image", "video":
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: fullImageRequestOptions
            ) { _, _, info, _ in
                if let fileURL = info?[PHImageFileURLKey] as? URL {
                    completion(fileURL.relativePath)
                } else {
                    completion(nil)
                }
            }
        case "audio":
            let resources = PHAssetResource.assetResources(for: asset)
            guard let audioResource = resources.first else {
                completion(nil)
                return
            }
            
            PHAssetResourceManager.default().requestData(
                for: audioResource,
                options: nil
            ) { _, info, error in
                if let error = error {
                    print("获取音频资源失败：\(error.localizedDescription)")
                    completion(nil)
                    return
                }
                if let fileURL = info?[PHAssetResourceDataRequestInfoFileURLKey] as? URL {
                    completion(fileURL.relativePath)
                } else {
                    completion(nil)
                }
            }
        default:
            completion(nil)
        }
    }
    
    // MARK: - 私有方法：获取资源文件名和MIME类型
    private func getAssetFileNameAndMIME(asset: PHAsset, completion: @escaping (String?, String?) -> Void) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            completion(nil, nil)
            return
        }
        
        // 文件名
        let fileName = resource.originalFilename
        // 文件后缀
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        // MIME类型
        let mimeType = mimeTypes[fileExtension]
        
        completion(fileName, mimeType)
    }
    
    // MARK: - 私有方法：图片尺寸精确缩放（TODO完成）
    private func resizeImage(to targetSize: CGSize, image: UIImage) -> UIImage {
        let targetRect = CGRect(origin: .zero, size: targetSize)
        UIGraphicsBeginImageContextWithOptions(targetSize, false, UIScreen.main.scale)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(in: targetRect)
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
    
    // MARK: - 私有方法：PHAssetMediaType转字符串
    private func mediaTypeString(from type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }
    
    // MARK: - 私有方法：照片权限检查
    private func checkPhotoPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                completion(newStatus == .authorized)
            }
        @unknown default:
            completion(false)
        }
    }
}
