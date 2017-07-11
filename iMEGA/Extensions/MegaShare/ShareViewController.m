
#import "ShareViewController.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import "LTHPasscodeViewController.h"
#import "SAMKeychain.h"
#import "SVProgressHUD.h"

#import "BrowserViewController.h"
#import "Helper.h"
#import "LaunchViewController.h"
#import "LoginRequiredViewController.h"
#import "MEGALogger.h"
#import "MEGARequestDelegate.h"
#import "MEGASdk.h"
#import "MEGASdkManager.h"
#import "MEGATransferDelegate.h"

#define kAppKey @"EVtjzb7R"
#define kUserAgent @"MEGAiOS"

#define MNZ_ANIMATION_TIME 0.35

@interface ShareViewController () <BrowserViewControllerDelegate, MEGARequestDelegate, MEGATransferDelegate, LTHPasscodeViewControllerDelegate>

@property (nonatomic) UIViewController *browserVC;
@property (nonatomic) unsigned long pendingAssets;
@property (nonatomic) unsigned long totalAssets;
@property (nonatomic) unsigned long unsupportedAssets;
@property (nonatomic) float progress;

@property (nonatomic) UINavigationController *loginRequiredNC;
@property (nonatomic) LaunchViewController *launchVC;
@property (nonatomic, getter=isFirstFetchNodesRequestUpdate) BOOL firstFetchNodesRequestUpdate;
@property (nonatomic, getter=isFirstAPI_EAGAIN) BOOL firstAPI_EAGAIN;
@property (nonatomic) NSTimer *timerAPI_EAGAIN;

@property (nonatomic) NSString *session;
@property (nonatomic) UIView *privacyView;

@property (nonatomic) BOOL fetchNodesDone;
@property (nonatomic) BOOL passcodePresented;

@end

@implementation ShareViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    if ([[[NSUserDefaults alloc] initWithSuiteName:@"group.mega.ios"] boolForKey:@"logging"]) {
        [[MEGALogger sharedLogger] enableSDKlogs];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *logsPath = [[[fileManager containerURLForSecurityApplicationGroupIdentifier:@"group.mega.ios"] URLByAppendingPathComponent:@"logs"] path];
        if (![fileManager fileExistsAtPath:logsPath]) {
            [fileManager createDirectoryAtPath:logsPath withIntermediateDirectories:NO attributes:nil error:nil];
        }
        [[MEGALogger sharedLogger] startLoggingToFile:[logsPath stringByAppendingPathComponent:@"MEGAiOS.shareExt.log"]];
    }
    
    self.fetchNodesDone = NO;
    self.passcodePresented = NO;
    
    [MEGASdkManager setAppKey:kAppKey];
    NSString *userAgent = [NSString stringWithFormat:@"%@/%@", kUserAgent, [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
    [MEGASdkManager setUserAgent:userAgent];
    [self languageCompatibility];
    
#ifdef DEBUG
    [MEGASdk setLogLevel:MEGALogLevelMax];
    [[MEGALogger sharedLogger] enableSDKlogs];
#else
    [MEGASdk setLogLevel:MEGALogLevelFatal];
#endif
    
    // Add a observer to get notified when the extension come back to the foreground:
    if ([[UIDevice currentDevice] systemVersionGreaterThanOrEqualVersion:@"8.2"]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willResignActive)
                                                     name:NSExtensionHostWillResignActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive)
                                                     name:NSExtensionHostDidBecomeActiveNotification
                                                   object:nil];
    }
    
    [self setupAppearance];
    [SVProgressHUD setViewForExtension:self.view];
    
    self.session = [SAMKeychain passwordForService:@"MEGA" account:@"sessionV3"];
    if (self.session) {
        // Common scenario, present the browser after passcode.
        [[LTHPasscodeViewController sharedUser] setDelegate:self];
        if ([LTHPasscodeViewController doesPasscodeExist]) {
            if ([[NSUserDefaults standardUserDefaults] boolForKey:kIsEraseAllLocalDataEnabled]) {
                [[LTHPasscodeViewController sharedUser] setMaxNumberOfAllowedFailedAttempts:10];
            }
            [self presentPasscode];
        } else {
            [self loginToMEGA];
        }
    } else {
        [self requireLogin];
    }
}

- (void)viewWillAppear:(BOOL)animated{
    [super viewWillAppear:animated];
    [self fakeModalPresentation];
}

- (void)willResignActive {
    if (self.session) {
        UIViewController *privacyVC = [[UIStoryboard storyboardWithName:@"Launch" bundle:[NSBundle bundleForClass:[LaunchViewController class]]] instantiateViewControllerWithIdentifier:@"PrivacyViewControllerID"];
        privacyVC.view.frame = CGRectMake(0.0f, 0.0f, self.view.frame.size.width, self.view.frame.size.height);
        self.privacyView = privacyVC.view;
        [self.view addSubview:self.privacyView];
    }
}

- (void)didBecomeActive {
    if (self.privacyView) {
        [self.privacyView removeFromSuperview];
        self.privacyView = nil;
    }
    
    self.session = [SAMKeychain passwordForService:@"MEGA" account:@"sessionV3"];
    if (self.session) {
        if (self.loginRequiredNC) {
            [self.loginRequiredNC dismissViewControllerAnimated:YES completion:nil];
        }
        if ([LTHPasscodeViewController doesPasscodeExist]) {
            [self presentPasscode];
        } else {
            if (!self.fetchNodesDone) {
                [self loginToMEGA];
            }
        }
    } else {
        [self requireLogin];
    }
}

#pragma mark - Language

- (void)languageCompatibility {
    
    NSString *currentLanguageID = [[LocalizationSystem sharedLocalSystem] getLanguage];
    
    if ([Helper isLanguageSupported:currentLanguageID]) {
        [[LocalizationSystem sharedLocalSystem] setLanguage:currentLanguageID];
    } else {
        [self setLanguage:currentLanguageID];
    }
}

- (void)setLanguage:(NSString *)languageID {
    NSDictionary *componentsFromLocaleID = [NSLocale componentsFromLocaleIdentifier:languageID];
    NSString *languageDesignator = [componentsFromLocaleID valueForKey:NSLocaleLanguageCode];
    if ([Helper isLanguageSupported:languageDesignator]) {
        [[LocalizationSystem sharedLocalSystem] setLanguage:languageDesignator];
    } else {
        [self setSystemLanguage];
    }
}

- (void)setSystemLanguage {
    NSDictionary *globalDomain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"NSGlobalDomain"];
    NSArray *languages = [globalDomain objectForKey:@"AppleLanguages"];
    NSString *systemLanguageID = [languages objectAtIndex:0];
    
    if ([Helper isLanguageSupported:systemLanguageID]) {
        [[LocalizationSystem sharedLocalSystem] setLanguage:systemLanguageID];
        return;
    }
    
    NSDictionary *componentsFromLocaleID = [NSLocale componentsFromLocaleIdentifier:systemLanguageID];
    NSString *languageDesignator = [componentsFromLocaleID valueForKey:NSLocaleLanguageCode];
    if ([Helper isLanguageSupported:languageDesignator]) {
        [[LocalizationSystem sharedLocalSystem] setLanguage:languageDesignator];
    } else {
        [self setDefaultLanguage];
    }
}

- (void)setDefaultLanguage {
    [[MEGASdkManager sharedMEGASdk] setLanguageCode:@"en"];
    [[LocalizationSystem sharedLocalSystem] setLanguage:@"en"];
}

#pragma mark - Login and Setup

- (void)requireLogin {
    // The user either needs to login or logged in before the current version of the MEGA app, so there is
    // no session stored in the shared keychain. In both scenarios, a ViewController from MEGA app is to be pushed.
    if (!self.loginRequiredNC) {
        self.loginRequiredNC = [[UIStoryboard storyboardWithName:@"LoginRequired"
                                                          bundle:[NSBundle bundleForClass:[LoginRequiredViewController class]]] instantiateViewControllerWithIdentifier:@"LoginRequiredNavigationControllerID"];
        
        LoginRequiredViewController *loginRequiredVC = self.loginRequiredNC.childViewControllers.firstObject;
        loginRequiredVC.navigationItem.title = @"MEGA";
        loginRequiredVC.cancelBarButtonItem.title = AMLocalizedString(@"cancel", nil);
        loginRequiredVC.cancelCompletion = ^{
            [self.loginRequiredNC dismissViewControllerAnimated:YES completion:^{
                [self dismissWithCompletionHandler:^{
                    [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
                }];
            }];
        };
        
        [self presentViewController:self.loginRequiredNC animated:YES completion:nil];
    }
}

- (void)setupAppearance {
    [[UINavigationBar appearance] setTitleTextAttributes:@{NSFontAttributeName:[UIFont mnz_SFUIRegularWithSize:17.0f]}];
    [[UINavigationBar appearance] setTintColor:[UIColor mnz_redD90007]];
    [[UINavigationBar appearance] setBackgroundColor:[UIColor mnz_grayF9F9F9]];
    
    [[UISegmentedControl appearance] setTitleTextAttributes:@{NSFontAttributeName:[UIFont mnz_SFUIRegularWithSize:13.0f]} forState:UIControlStateNormal];
    
    [[UIBarButtonItem appearance] setTintColor:[UIColor mnz_redD90007]];
    [[UIBarButtonItem appearance] setTitleTextAttributes:@{NSFontAttributeName:[UIFont mnz_SFUIRegularWithSize:17.0f]} forState:UIControlStateNormal];
    UIImage *backButtonImage = [[UIImage imageNamed:@"backArrow"] resizableImageWithCapInsets:UIEdgeInsetsMake(0, 22, 0, 0)];
    [[UIBarButtonItem appearance] setBackButtonBackgroundImage:backButtonImage forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    
    [[UITextField appearance] setTintColor:[UIColor mnz_redD90007]];
    [[UITextField appearanceWhenContainedIn:[UISearchBar class], nil] setBackgroundColor:[UIColor mnz_grayF9F9F9]];
    
    [[UIView appearanceWhenContainedIn:[UIAlertController class], nil] setTintColor:[UIColor mnz_redD90007]];
    
    [self configureProgressHUD];
}

- (void)configureProgressHUD {
    [SVProgressHUD setViewForExtension:self.view];
    
    [SVProgressHUD setFont:[UIFont mnz_SFUIRegularWithSize:12.0f]];
    [SVProgressHUD setRingThickness:2.0];
    [SVProgressHUD setRingNoTextRadius:18.0];
    [SVProgressHUD setBackgroundColor:[UIColor mnz_grayF7F7F7]];
    [SVProgressHUD setForegroundColor:[UIColor mnz_gray666666]];
    [SVProgressHUD setDefaultStyle:SVProgressHUDStyleCustom];
    
    [SVProgressHUD setSuccessImage:[UIImage imageNamed:@"hudSuccess"]];
    [SVProgressHUD setErrorImage:[UIImage imageNamed:@"hudError"]];
}

- (IBAction)openMegaTouchUpInside:(id)sender {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"mega://#loginrequired"]];
}

- (void)loginToMEGA {
    self.navigationItem.title = @"MEGA";
    
    LaunchViewController *launchVC = [[UIStoryboard storyboardWithName:@"Launch" bundle:[NSBundle bundleForClass:[LaunchViewController class]]] instantiateViewControllerWithIdentifier:@"LaunchViewControllerID"];
    launchVC.view.frame = CGRectMake(0.0f, 0.0f, self.view.frame.size.width, self.view.frame.size.height);
    self.launchVC = launchVC;
    [self.view addSubview:self.launchVC.view];
    
    [[MEGASdkManager sharedMEGASdk] fastLoginWithSession:self.session delegate:self];
}

- (void)presentDocumentPicker {
    UIStoryboard *cloudStoryboard = [UIStoryboard storyboardWithName:@"Cloud" bundle:[NSBundle bundleForClass:BrowserViewController.class]];
    UINavigationController *navigationController = [cloudStoryboard instantiateViewControllerWithIdentifier:@"BrowserNavigationControllerID"];
    BrowserViewController *browserVC = navigationController.viewControllers.firstObject;
    browserVC.browserAction = BrowserActionShareExtension;
    browserVC.browserViewControllerDelegate = self;
    
    [self addChildViewController:navigationController];
    [navigationController.view setFrame:CGRectMake(0.0f, 0.0f, self.view.frame.size.width, self.view.frame.size.height)];
    [self.view addSubview:navigationController.view];
}

- (void)presentPasscode {
    if (!self.passcodePresented) {
        LTHPasscodeViewController *passcodeVC = [LTHPasscodeViewController sharedUser];
        [passcodeVC showLockScreenOver:self.view.superview
                         withAnimation:YES
                            withLogout:YES
                        andLogoutTitle:AMLocalizedString(@"logoutLabel", nil)];
        
        [passcodeVC.view setFrame:CGRectMake(0.0f, 0.0f, self.view.frame.size.width, self.view.frame.size.height)];
        [self presentViewController:passcodeVC animated:NO completion:nil];
        self.passcodePresented = YES;
    }
}

- (void)startTimerAPI_EAGAIN {
    self.timerAPI_EAGAIN = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(showServersTooBusy) userInfo:nil repeats:NO];
}

- (void)showServersTooBusy {
    [self.launchVC.label setText:AMLocalizedString(@"serversTooBusy", @"Message shown when you launch the app and it gets frozen because the servers are too busy so it may take a while until you get response and log in")];
}

- (void)fakeModalPresentation {
    self.view.transform = CGAffineTransformMakeTranslation(0, self.view.frame.size.height);
    [UIView animateWithDuration:MNZ_ANIMATION_TIME animations:^{
        self.view.transform = CGAffineTransformIdentity;
    }];
}

- (void)dismissWithCompletionHandler:(void (^)(void))completion {
    [UIView animateWithDuration:MNZ_ANIMATION_TIME
                     animations:^{
                         self.view.transform = CGAffineTransformMakeTranslation(0, self.view.frame.size.height);
                     }
                     completion:^(BOOL finished) {
                         if (completion) {
                             completion();
                         }
                     }];
}

#pragma mark - Share Extension Code

- (void)downloadData:(NSURL *)url andUploadToParentNode:(MEGANode *)parentNode {
    NSURL *urlToDownload = url;
    NSString *urlString = [url absoluteString];
    if ([urlString hasPrefix:@"https://www.dropbox.com"]) {
        // Fix for Dropbox:
        urlString = [urlString stringByReplacingOccurrencesOfString:@"dl=0" withString:@"dl=1"];
        urlToDownload = [NSURL URLWithString:urlString];
    }
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:urlToDownload
                                                                             completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                                                                         [self uploadData:location toParentNode:parentNode withFileName:response.suggestedFilename];
                                                                     }];
    [downloadTask resume];
}

- (void)uploadData:(NSURL *)url toParentNode:(MEGANode *)parentNode {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *storagePath = [self shareExtensionStorage];
    NSString *path = [url path];
    NSString *tempPath = [storagePath stringByAppendingPathComponent:[path lastPathComponent]];
    if ([fileManager copyItemAtPath:path toPath:tempPath error:nil]) {
        [self smartUploadLocalPath:tempPath parent:parentNode];
    } else {
        [self oneLess];
    }
}

- (void)uploadData:(NSURL *)url toParentNode:(MEGANode *)parentNode withFileName:(NSString *)filename {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *storagePath = [self shareExtensionStorage];
    NSString *path = [url path];
    NSString *tempPath = [storagePath stringByAppendingPathComponent:filename];
    // The file needs to be moved in this case because it is downloaded with a temporal filename
    if ([fileManager moveItemAtPath:path toPath:tempPath error:nil]) {
        [self smartUploadLocalPath:tempPath parent:parentNode];
    } else {
        [self oneLess];
    }
}

- (NSString *)shareExtensionStorage {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *storagePath = [[[fileManager containerURLForSecurityApplicationGroupIdentifier:@"group.mega.ios"] URLByAppendingPathComponent:@"Share Extension Storage"] path];
    if (![fileManager fileExistsAtPath:storagePath]) {
        [fileManager createDirectoryAtPath:storagePath withIntermediateDirectories:NO attributes:nil error:nil];
    }
    return storagePath;
}

- (void)smartUploadLocalPath:(NSString *)localPath parent:(MEGANode *)parentNode {
    NSString *localFingerprint = [[MEGASdkManager sharedMEGASdk] fingerprintForFilePath:localPath];
    MEGANode *remoteNode = [[MEGASdkManager sharedMEGASdk] nodeForFingerprint:localFingerprint parent:parentNode];
    if (remoteNode) {
        if (remoteNode.parentHandle == parentNode.handle) {
            // The file is already in the folder, nothing to do.
            [self oneLess];
        } else {
            if ([remoteNode.name isEqualToString:localPath.lastPathComponent]) {
                // The file is already in MEGA, in other folder, has to be copied to this folder.
                [[MEGASdkManager sharedMEGASdk] copyNode:remoteNode newParent:parentNode delegate:self];
            } else {
                // The file is already in MEGA, in other folder with different name, has to be copied to this folder and renamed.
                [[MEGASdkManager sharedMEGASdk] copyNode:remoteNode newParent:parentNode newName:localPath.lastPathComponent delegate:self];
            }
        }
        [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
    } else {
        // The file is not in MEGA.
        [[MEGASdkManager sharedMEGASdk] startUploadWithLocalPath:localPath parent:parentNode appData:nil isSourceTemporary:YES delegate:self];
    }
}

- (void)oneLess {
    if (--self.pendingAssets == self.unsupportedAssets) {
        [SVProgressHUD setDefaultMaskType:SVProgressHUDMaskTypeNone];
        [SVProgressHUD dismiss];
        [self dismissWithCompletionHandler:^{
            [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
        }];
    }
}

#pragma mark - BrowserViewControllerDelegate

- (void)uploadToParentNode:(MEGANode *)parentNode {
    if (parentNode) {
        // The user tapped "Upload":
        [self setupAppearance];
        [SVProgressHUD setDefaultMaskType:SVProgressHUDMaskTypeClear];
        [SVProgressHUD show];
        
        NSExtensionItem *content = self.extensionContext.inputItems[0];
        self.totalAssets = self.pendingAssets = content.attachments.count;
        self.progress = 0;
        self.unsupportedAssets = 0;
        for (NSItemProvider *attachment in content.attachments) {
            if ([attachment hasItemConformingToTypeIdentifier:(NSString *)kUTTypeImage]) {
                [attachment loadItemForTypeIdentifier:(NSString *)kUTTypeImage options:nil completionHandler:^(id data, NSError *error){
                    [self uploadData:(NSURL *)data toParentNode:parentNode];
                }];
            } else if ([attachment hasItemConformingToTypeIdentifier:(NSString *)kUTTypeMovie]) {
                [attachment loadItemForTypeIdentifier:(NSString *)kUTTypeMovie options:nil completionHandler:^(id data, NSError *error){
                    [self uploadData:(NSURL *)data toParentNode:parentNode];
                }];
            } else if ([attachment hasItemConformingToTypeIdentifier:(NSString *)kUTTypeFileURL]) {
                // This type includes kUTTypeText, so kUTTypeText it's omitted
                [attachment loadItemForTypeIdentifier:(NSString *)kUTTypeFileURL options:nil completionHandler:^(id data, NSError *error){
                    [self uploadData:(NSURL *)data toParentNode:parentNode];
                }];
            } else if ([attachment hasItemConformingToTypeIdentifier:(NSString *)kUTTypeURL]) {
                [attachment loadItemForTypeIdentifier:(NSString *)kUTTypeURL options:nil completionHandler:^(id data, NSError *error){
                    [self downloadData:(NSURL *)data andUploadToParentNode:parentNode];
                }];
            } else {
                self.unsupportedAssets++;
            }
        }
        // If there is no supported asset to process, then the extension is done:
        if (self.pendingAssets == self.unsupportedAssets) {
            [self dismissWithCompletionHandler:^{
                [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
            }];
        }
    } else {
        // The user tapped "Cancel":
        [self dismissWithCompletionHandler:^{
            [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
        }];
    }
}

#pragma mark - MEGARequestDelegate

- (void)onRequestStart:(MEGASdk *)api request:(MEGARequest *)request {
    switch ([request type]) {
        case MEGARequestTypeLogin:
        case MEGARequestTypeFetchNodes: {
            self.launchVC.activityIndicatorView.hidden = NO;
            [self.launchVC.activityIndicatorView startAnimating];
            
            self.firstAPI_EAGAIN = YES;
            self.firstFetchNodesRequestUpdate = YES;
            break;
        }
            
        default:
            break;
    }
}

- (void)onRequestUpdate:(MEGASdk *)api request:(MEGARequest *)request {
    if (request.type == MEGARequestTypeFetchNodes) {
        float progress = (request.transferredBytes.floatValue / request.totalBytes.floatValue);
        
        if (self.isFirstFetchNodesRequestUpdate) {
            [self.launchVC.activityIndicatorView stopAnimating];
            self.launchVC.activityIndicatorView.hidden = YES;
            
            [self.launchVC.logoImageView.layer addSublayer:self.launchVC.circularShapeLayer];
            self.launchVC.circularShapeLayer.strokeStart = 0.0f;
        }
        
        if (progress > 0 && progress <= 1.0) {
            self.launchVC.circularShapeLayer.strokeEnd = progress;
        }
    }
}

- (void)onRequestFinish:(MEGASdk *)api request:(MEGARequest *)request error:(MEGAError *)error {
    switch ([request type]) {
        case MEGARequestTypeLogin: {
            [api fetchNodesWithDelegate:self];
            break;
        }
            
        case MEGARequestTypeFetchNodes: {
            self.fetchNodesDone = YES;
            [self.launchVC.view removeFromSuperview];
            [self presentDocumentPicker];
            break;
        }
            
        case MEGARequestTypeCopy: {
            [self oneLess];
            break;
        }
            
        default:
            break;
    }
}

- (void)onRequestTemporaryError:(MEGASdk *)api request:(MEGARequest *)request error:(MEGAError *)error {
    switch (request.type) {
        case MEGARequestTypeLogin:
        case MEGARequestTypeFetchNodes: {
            if (self.isFirstAPI_EAGAIN) {
                [self startTimerAPI_EAGAIN];
                self.firstAPI_EAGAIN = NO;
            }
            break;
        }
            
        default:
            break;
    }
}

#pragma mark - MEGATransferDelegate

- (void)onTransferUpdate:(MEGASdk *)api transfer:(MEGATransfer *)transfer {
    self.progress += (transfer.deltaSize.floatValue / transfer.totalBytes.floatValue) / self.totalAssets;
    if (self.progress >= 0.01) {
        NSString *progressCompleted = [NSString stringWithFormat:@"%.f %%", floor(self.progress * 100)];
        [SVProgressHUD showProgress:self.progress status:progressCompleted];
    }
}

- (void)onTransferFinish:(MEGASdk *)api transfer:(MEGATransfer *)transfer error:(MEGAError *)error {
    [self oneLess];
}

#pragma mark - LTHPasscodeViewControllerDelegate

- (void)passcodeWasEnteredSuccessfully {
    [self dismissViewControllerAnimated:YES completion:^{
        self.passcodePresented = NO;
        if (!self.fetchNodesDone) {
            [self loginToMEGA];
        }
    }];
}

- (void)maxNumberOfFailedAttemptsReached {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kIsEraseAllLocalDataEnabled]) {
        [[MEGASdkManager sharedMEGASdk] logout];
    }
}

- (void)logoutButtonWasPressed {
    [[MEGASdkManager sharedMEGASdk] logout];
}

@end
