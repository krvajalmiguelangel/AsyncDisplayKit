/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ASNetworkImageNode.h"

#import "ASBasicImageDownloader.h"
#import "ASDisplayNode+Subclasses.h"
#import "ASDisplayNode+FrameworkPrivate.h"
#import "ASEqualityHelpers.h"
#import "ASThread.h"
#import "ASInternalHelpers.h"
#import "ASImageContainerProtocolCategories.h"
#import "ASDisplayNodeExtras.h"

#if PIN_REMOTE_IMAGE
#import "ASPINRemoteImageDownloader.h"
#endif

static const CGSize kMinReleaseImageOnBackgroundSize = {20.0, 20.0};

@interface ASNetworkImageNode ()
{
  ASDN::RecursiveMutex _lock;
  __weak id<ASImageCacheProtocol, ASImageCacheProtocolDeprecated> _cache;
  __weak id<ASImageDownloaderProtocol, ASImageDownloaderProtocolDeprecated> _downloader;

  // Only access any of these with _lock.
  __weak id<ASNetworkImageNodeDelegate> _delegate;

  NSURL *_URL;
  UIImage *_defaultImage;

  NSUUID *_cacheUUID;
  id _downloadIdentifier;

  BOOL _imageLoaded;
  CGFloat _currentImageQuality;
  CGFloat _renderedImageQuality;

  BOOL _delegateSupportsDidStartFetchingData;
  BOOL _delegateSupportsDidFailWithError;
  BOOL _delegateSupportsImageNodeDidFinishDecoding;
  
  BOOL _shouldRenderProgressImages;

  //set on init only
  BOOL _downloaderSupportsNewProtocol;
  BOOL _downloaderImplementsSetProgress;
  BOOL _downloaderImplementsSetPriority;
  BOOL _downloaderImplementsAnimatedImage;

  BOOL _cacheSupportsNewProtocol;
  BOOL _cacheSupportsClearing;
  BOOL _cacheSupportsSynchronousFetch;
}
@end

@implementation ASNetworkImageNode

- (instancetype)initWithCache:(id<ASImageCacheProtocol>)cache downloader:(id<ASImageDownloaderProtocol>)downloader
{
  if (!(self = [super init]))
    return nil;

  _cache = (id<ASImageCacheProtocol, ASImageCacheProtocolDeprecated>)cache;
  _downloader = (id<ASImageDownloaderProtocol, ASImageDownloaderProtocolDeprecated>)downloader;
  
  ASDisplayNodeAssert([downloader respondsToSelector:@selector(downloadImageWithURL:callbackQueue:downloadProgress:completion:)] || [downloader respondsToSelector:@selector(downloadImageWithURL:callbackQueue:downloadProgressBlock:completion:)], @"downloader must respond to either downloadImageWithURL:callbackQueue:downloadProgress:completion: or downloadImageWithURL:callbackQueue:downloadProgressBlock:completion:.");
  
  _downloaderSupportsNewProtocol = [downloader respondsToSelector:@selector(downloadImageWithURL:callbackQueue:downloadProgress:completion:)];
  
  ASDisplayNodeAssert(cache == nil || [cache respondsToSelector:@selector(cachedImageWithURL:callbackQueue:completion:)] || [cache respondsToSelector:@selector(fetchCachedImageWithURL:callbackQueue:completion:)], @"cacher must respond to either cachedImageWithURL:callbackQueue:completion: or fetchCachedImageWithURL:callbackQueue:completion:");
  
  _downloaderImplementsSetProgress = [downloader respondsToSelector:@selector(setProgressImageBlock:callbackQueue:withDownloadIdentifier:)];
  _downloaderImplementsSetPriority = [downloader respondsToSelector:@selector(setPriority:withDownloadIdentifier:)];
  _downloaderImplementsAnimatedImage = [downloader respondsToSelector:@selector(animatedImageWithData:)];
  
  _cacheSupportsNewProtocol = [cache respondsToSelector:@selector(cachedImageWithURL:callbackQueue:completion:)];
  _cacheSupportsClearing = [cache respondsToSelector:@selector(clearFetchedImageFromCacheWithURL:)];
  _cacheSupportsSynchronousFetch = [cache respondsToSelector:@selector(synchronouslyFetchedCachedImageWithURL:)];
  
  _shouldCacheImage = YES;
  _shouldRenderProgressImages = YES;
  self.shouldBypassEnsureDisplay = YES;

  return self;
}

- (instancetype)init
{
#if PIN_REMOTE_IMAGE
  return [self initWithCache:[ASPINRemoteImageDownloader sharedDownloader] downloader:[ASPINRemoteImageDownloader sharedDownloader]];
#else
  return [self initWithCache:nil downloader:[ASBasicImageDownloader sharedImageDownloader]];
#endif
}

- (void)dealloc
{
  [self _cancelImageDownload];
}

#pragma mark - Public methods -- must lock

- (void)setURL:(NSURL *)URL
{
  [self setURL:URL resetToDefault:YES];
}

- (void)setURL:(NSURL *)URL resetToDefault:(BOOL)reset
{
  ASDN::MutexLocker l(_lock);

  if (ASObjectIsEqual(URL, _URL)) {
    return;
  }

  [self _cancelImageDownload];
  _imageLoaded = NO;

  _URL = URL;

  BOOL hasURL = _URL == nil;
  if (reset || hasURL) {
    self.image = _defaultImage;
    /* We want to maintain the order that currentImageQuality is set regardless of the calling thread,
     so always use a dispatch_async to ensure that we queue the operations in the correct order.
     (see comment in displayDidFinish) */
    dispatch_async(dispatch_get_main_queue(), ^{
      self.currentImageQuality = hasURL ? 0.0 : 1.0;
    });
  }

  if (self.interfaceState & ASInterfaceStateFetchData) {
    [self fetchData];
  }
}

- (NSURL *)URL
{
  ASDN::MutexLocker l(_lock);
  return _URL;
}

- (void)setDefaultImage:(UIImage *)defaultImage
{
  _lock.lock();

  if (ASObjectIsEqual(defaultImage, _defaultImage)) {
    _lock.unlock();
    return;
  }
  _defaultImage = defaultImage;

  if (!_imageLoaded) {
    BOOL hasURL = _URL == nil;
    /* We want to maintain the order that currentImageQuality is set regardless of the calling thread,
     so always use a dispatch_async to ensure that we queue the operations in the correct order.
     (see comment in displayDidFinish) */
    dispatch_async(dispatch_get_main_queue(), ^{
      self.currentImageQuality = hasURL ? 0.0 : 1.0;
    });
    _lock.unlock();
    // Locking: it is important to release _lock before entering setImage:, as it needs to release the lock before -invalidateCalculatedLayout.
    // If we continue to hold the lock here, it will still be locked until the next unlock() call, causing a possible deadlock with
    // -[ASNetworkImageNode displayWillStart] (which is called on a different thread / main, at an unpredictable time due to ASMainRunloopQueue).
    self.image = defaultImage;
  } else {
    _lock.unlock();
  }
}

- (UIImage *)defaultImage
{
  ASDN::MutexLocker l(_lock);
  return _defaultImage;
}

- (void)setCurrentImageQuality:(CGFloat)currentImageQuality
{
  ASDN::MutexLocker l(_lock);
  _currentImageQuality = currentImageQuality;
}

- (CGFloat)currentImageQuality
{
  ASDN::MutexLocker l(_lock);
  return _currentImageQuality;
}

- (void)setRenderedImageQuality:(CGFloat)renderedImageQuality
{
  ASDN::MutexLocker l(_lock);
  _renderedImageQuality = renderedImageQuality;
}

- (CGFloat)renderedImageQuality
{
  ASDN::MutexLocker l(_lock);
  return _renderedImageQuality;
}

- (void)setDelegate:(id<ASNetworkImageNodeDelegate>)delegate
{
  ASDN::MutexLocker l(_lock);
  _delegate = delegate;
  
  _delegateSupportsDidStartFetchingData = [delegate respondsToSelector:@selector(imageNodeDidStartFetchingData:)];
  _delegateSupportsDidFailWithError = [delegate respondsToSelector:@selector(imageNode:didFailWithError:)];
  _delegateSupportsImageNodeDidFinishDecoding = [delegate respondsToSelector:@selector(imageNodeDidFinishDecoding:)];
}

- (id<ASNetworkImageNodeDelegate>)delegate
{
  ASDN::MutexLocker l(_lock);
  return _delegate;
}

- (void)setShouldRenderProgressImages:(BOOL)shouldRenderProgressImages
{
  ASDN::MutexLocker l(_lock);
  if (shouldRenderProgressImages == _shouldRenderProgressImages) {
    return;
  }
  
  _shouldRenderProgressImages = shouldRenderProgressImages;
  
  
  ASDN::MutexUnlocker u(_lock);
  [self _updateProgressImageBlockOnDownloaderIfNeeded];
}

- (BOOL)shouldRenderProgressImages
{
  ASDN::MutexLocker l(_lock);
  return _shouldRenderProgressImages;
}

- (BOOL)placeholderShouldPersist
{
  ASDN::MutexLocker l(_lock);
  return (self.image == nil && _URL != nil);
}

/* displayWillStart in ASMultiplexImageNode has a very similar implementation. Changes here are likely necessary
 in ASMultiplexImageNode as well. */
- (void)displayWillStart
{
  [super displayWillStart];
  
  if (_cacheSupportsSynchronousFetch) {
    ASDN::MutexLocker l(_lock);
    if (_imageLoaded == NO && _URL && _downloadIdentifier == nil) {
      UIImage *result = [[_cache synchronouslyFetchedCachedImageWithURL:_URL] asdk_image];
      if (result) {
        self.image = result;
        _imageLoaded = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
          _currentImageQuality = 1.0;
        });
      }
    }
  }

  [self fetchData];
  
  if (self.image == nil && _downloaderImplementsSetPriority) {
    ASDN::MutexLocker l(_lock);
    if (_downloadIdentifier != nil) {
      [_downloader setPriority:ASImageDownloaderPriorityImminent withDownloadIdentifier:_downloadIdentifier];
    }
  }
}

/* visibilityDidChange in ASMultiplexImageNode has a very similar implementation. Changes here are likely necessary
 in ASMultiplexImageNode as well. */
- (void)visibilityDidChange:(BOOL)isVisible
{
  [super visibilityDidChange:isVisible];

  if (_downloaderImplementsSetPriority) {
    _lock.lock();
    if (_downloadIdentifier != nil) {
      if (isVisible) {
        [_downloader setPriority:ASImageDownloaderPriorityVisible withDownloadIdentifier:_downloadIdentifier];
      } else {
        [_downloader setPriority:ASImageDownloaderPriorityPreload withDownloadIdentifier:_downloadIdentifier];
      }
    }
    _lock.unlock();
  }

  // This method has to be called without _lock held
  [self _updateProgressImageBlockOnDownloaderIfNeeded];
}

- (void)clearFetchedData
{
  [super clearFetchedData];

  {
    ASDN::MutexLocker l(_lock);

    [self _cancelImageDownload];
    [self _clearImage];
    if (_cacheSupportsClearing) {
      [_cache clearFetchedImageFromCacheWithURL:_URL];
    }
  }
}

- (void)fetchData
{
  [super fetchData];
  
  {
    ASDN::MutexLocker l(_lock);
    [self _lazilyLoadImageIfNecessary];
  }
}

#pragma mark - Private methods -- only call with lock.

/**
 @note: This should be called without _lock held. We will lock
 super to read our interface state and it's best to avoid acquiring both locks.
 */
- (void)_updateProgressImageBlockOnDownloaderIfNeeded
{
  BOOL shouldRenderProgressImages = self.shouldRenderProgressImages;
  
  // Read our interface state before locking so that we don't lock super while holding our lock.
  ASInterfaceState interfaceState = self.interfaceState;
  ASDN::MutexLocker l(_lock);

  if (!_downloaderImplementsSetProgress || _downloadIdentifier == nil) {
    return;
  }

  ASImageDownloaderProgressImage progress = nil;
  if (shouldRenderProgressImages && ASInterfaceStateIncludesVisible(interfaceState)) {
    __weak __typeof__(self) weakSelf = self;
    progress = ^(UIImage * _Nonnull progressImage, CGFloat progress, id _Nullable downloadIdentifier) {
      __typeof__(self) strongSelf = weakSelf;
      if (strongSelf == nil) {
        return;
      }

      ASDN::MutexLocker l(strongSelf->_lock);
      //Getting a result back for a different download identifier, download must not have been successfully canceled
      if (ASObjectIsEqual(strongSelf->_downloadIdentifier, downloadIdentifier) == NO && downloadIdentifier != nil) {
        return;
      }
      strongSelf.image = progressImage;
      dispatch_async(dispatch_get_main_queue(), ^{
        strongSelf->_currentImageQuality = progress;
      });
    };
  }
  [_downloader setProgressImageBlock:progress callbackQueue:dispatch_get_main_queue() withDownloadIdentifier:_downloadIdentifier];
}

- (void)_clearImage
{
  // Destruction of bigger images on the main thread can be expensive
  // and can take some time, so we dispatch onto a bg queue to
  // actually dealloc.
  __block UIImage *image = self.image;
  CGSize imageSize = image.size;
  BOOL shouldReleaseImageOnBackgroundThread = imageSize.width > kMinReleaseImageOnBackgroundSize.width ||
                                              imageSize.height > kMinReleaseImageOnBackgroundSize.height;
  if (shouldReleaseImageOnBackgroundThread) {
    ASPerformBlockOnBackgroundThread(^{
      image = nil;
    });
  }
  self.animatedImage = nil;
  self.image = _defaultImage;
  _imageLoaded = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    self.currentImageQuality = 0.0;
  });
}

- (void)_cancelImageDownload
{
  if (!_downloadIdentifier) {
    return;
  }

  if (_downloadIdentifier) {
    [_downloader cancelImageDownloadForIdentifier:_downloadIdentifier];
  }
  _downloadIdentifier = nil;

  _cacheUUID = nil;
}

- (void)_downloadImageWithCompletion:(void (^)(id <ASImageContainerProtocol> imageContainer, NSError*, id downloadIdentifier))finished
{
  ASPerformBlockOnBackgroundThread(^{
    _lock.lock();
    if (_downloaderSupportsNewProtocol) {
      _downloadIdentifier = [_downloader downloadImageWithURL:_URL
                                                callbackQueue:dispatch_get_main_queue()
                                             downloadProgress:NULL
                                                   completion:^(id <ASImageContainerProtocol> _Nullable imageContainer, NSError * _Nullable error, id  _Nullable downloadIdentifier) {
                                                     if (finished != NULL) {
                                                       finished(imageContainer, error, downloadIdentifier);
                                                     }
                                                   }];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      _downloadIdentifier = [_downloader downloadImageWithURL:_URL
                                                callbackQueue:dispatch_get_main_queue()
                                        downloadProgressBlock:NULL
                                                   completion:^(CGImageRef responseImage, NSError *error) {
                                                     if (finished != NULL) {
                                                       finished([UIImage imageWithCGImage:responseImage], error, nil);
                                                     }
                                                   }];
#pragma clang diagnostic pop
    }
    _lock.unlock();

    // This method has to be called without _lock held
    [self _updateProgressImageBlockOnDownloaderIfNeeded];
      
  });
}

- (void)_lazilyLoadImageIfNecessary
{
  // FIXME: We should revisit locking in this method (e.g. to access the instance variables at the top, and holding lock while calling delegate)
  if (!_imageLoaded && _URL != nil && _downloadIdentifier == nil) {
    {
      ASDN::MutexLocker l(_lock);
      if (_delegateSupportsDidStartFetchingData) {
        [_delegate imageNodeDidStartFetchingData:self];
      }
    }
    
    if (_URL.isFileURL) {
      {
        ASDN::MutexLocker l(_lock);

        dispatch_async(dispatch_get_main_queue(), ^{
          if (self.shouldCacheImage) {
            self.image = [UIImage imageNamed:_URL.path.lastPathComponent];
          } else {
            // First try to load the path directly, for efficiency assuming a developer who
            // doesn't want caching is trying to be as minimal as possible.
            self.image = [UIImage imageWithContentsOfFile:_URL.path];
            if (!self.image) {
              // If we couldn't find it, execute an -imageNamed:-like search so we can find resources even if the
              // extension is not provided in the path.  This allows the same path to work regardless of shouldCacheImage.
              NSString *filename = [[NSBundle mainBundle] pathForResource:_URL.path.lastPathComponent ofType:nil];
              if (filename) {
                self.image = [UIImage imageWithContentsOfFile:filename];
              }
            }
          }

          _imageLoaded = YES;
          /* We want to maintain the order that currentImageQuality is set regardless of the calling thread,
           so always use a dispatch_async to ensure that we queue the operations in the correct order.
           (see comment in displayDidFinish) */
          dispatch_async(dispatch_get_main_queue(), ^{
            self.currentImageQuality = 1.0;
          });
          [_delegate imageNode:self didLoadImage:self.image];
        });
      }
    } else {
      __weak __typeof__(self) weakSelf = self;
      void (^finished)(id <ASImageContainerProtocol>, NSError *, id downloadIdentifier) = ^(id <ASImageContainerProtocol>imageContainer, NSError *error, id downloadIdentifier) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
          return;
        }

        ASDN::MutexLocker l(strongSelf->_lock);
        
        //Getting a result back for a different download identifier, download must not have been successfully canceled
        if (ASObjectIsEqual(strongSelf->_downloadIdentifier, downloadIdentifier) == NO && downloadIdentifier != nil) {
            return;
        }

        if (imageContainer != nil) {
          strongSelf->_imageLoaded = YES;
          if ([imageContainer asdk_animatedImageData] && _downloaderImplementsAnimatedImage) {
            strongSelf.animatedImage = [_downloader animatedImageWithData:[imageContainer asdk_animatedImageData]];
          } else {
            strongSelf.image = [imageContainer asdk_image];
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf->_currentImageQuality = 1.0;
          });
        }

        strongSelf->_downloadIdentifier = nil;

        strongSelf->_cacheUUID = nil;

        if (imageContainer != nil) {
          [strongSelf->_delegate imageNode:strongSelf didLoadImage:strongSelf.image];
        }
        else if (error && strongSelf->_delegateSupportsDidFailWithError) {
          [strongSelf->_delegate imageNode:strongSelf didFailWithError:error];
        }
      };

      if (_cache != nil) {
        NSUUID *cacheUUID = [NSUUID UUID];
        _cacheUUID = cacheUUID;

        void (^cacheCompletion)(id <ASImageContainerProtocol>) = ^(id <ASImageContainerProtocol> imageContainer) {
          // If the cache UUID changed, that means this request was cancelled.
          if (!ASObjectIsEqual(_cacheUUID, cacheUUID)) {
            return;
          }
          
          if ([imageContainer asdk_image] == nil && _downloader != nil) {
            [self _downloadImageWithCompletion:finished];
          } else {
            finished(imageContainer, nil, nil);
          }
        };
        
        if (_cacheSupportsNewProtocol) {
          [_cache cachedImageWithURL:_URL
                       callbackQueue:dispatch_get_main_queue()
                          completion:cacheCompletion];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
          [_cache fetchCachedImageWithURL:_URL
                            callbackQueue:dispatch_get_main_queue()
                               completion:^(CGImageRef image) {
                                 cacheCompletion([UIImage imageWithCGImage:image]);
                               }];
#pragma clang diagnostic pop
        }
      } else {
        [self _downloadImageWithCompletion:finished];
      }
    }
  }
}

#pragma mark - ASDisplayNode+Subclasses

- (void)displayDidFinish
{
  [super displayDidFinish];

  ASDN::MutexLocker l(_lock);
  if (_delegateSupportsImageNodeDidFinishDecoding && self.layer.contents != nil) {
    /* We store the image quality in _currentImageQuality whenever _image is set. On the following displayDidFinish, we'll know that
     _currentImageQuality is the quality of the image that has just finished rendering. In order for this to be accurate, we
     need to be sure we are on main thread when we set _currentImageQuality. Otherwise, it is possible for _currentImageQuality
     to be modified at a point where it is too late to cancel the main thread's previous display (the final sentinel check has passed), 
     but before the displayDidFinish of the previous display pass is called. In this situation, displayDidFinish would be called and we
     would set _renderedImageQuality to the new _currentImageQuality, but the actual quality of the rendered image should be the previous 
     value stored in _currentImageQuality. */

    _renderedImageQuality = _currentImageQuality;
    [self.delegate imageNodeDidFinishDecoding:self];
  }
}

@end
