//
//  BMEAppDelegate.m
//  BeMyEyes
//
//  Created by Simon Støvring on 22/02/14.
//  Copyright (c) 2014 Be My Eyes. All rights reserved.
//

#import "BMEAppDelegate.h"
#import <Appirater/Appirater.h>
#import <PSAlertView/PSPDFAlertView.h>
#import <MRProgress/MRProgress.h>
#import "BMEClient.h"
#import "BMECallViewController.h"
#import "BMECallAudioPlayer.h"
#import "BMEAccessControlHandler.h"
#import <Crashlytics/Crashlytics.h>
#import "BMETopNavigationController.h"


@interface BMEAppDelegate () <UIAlertViewDelegate>
@property (strong, nonatomic) PSPDFAlertView *callAlertView;
@property (strong, nonatomic) BMECallAudioPlayer *callAudioPlayer;
@property (assign, nonatomic, getter = isLaunchedWithShortID) BOOL launchedWithShortID;
@property (assign, nonatomic, getter = isLaunchedFromDemoCall) BOOL launchedFromDemoCall;
@property (strong, nonatomic) InAppTestBadge *inAppTestBadgeWindow;
@end

@implementation BMEAppDelegate

#pragma mark -
#pragma mark Lifecycle

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Environment
    BOOL isStaging = NO;
    BOOL isDevelopment = NO;
    
    switch ([ApplicationProperties environment])
    {
        case ApplicationEnvironmentProduction:
            [GVUserDefaults standardUserDefaults].api = BMESettingsAPIPublic;
            NSLog(@"API: Production");
            break;
            
        case ApplicationEnvironmentStaging:
            isStaging = YES;
            [GVUserDefaults standardUserDefaults].api = BMESettingsAPIStaging;
            NSLog(@"API: Staging");
            break;
            
        case ApplicationEnvironmentDevelopment:
            isDevelopment = YES;
            NSLog(@"API: Development");
            [GVUserDefaults standardUserDefaults].api = BMESettingsAPIDevelopment;
            break;
            
        default:
            NSLog(@"Unable to determine app environment. Fallback to Development");
            [GVUserDefaults standardUserDefaults].api = BMESettingsAPIDevelopment;
            isDevelopment = YES;
            break;
    }
    
    // Provisioning: Production / Development
    BOOL isDebug;
#ifdef DEBUG
    isDebug = YES;
#else
    isDebug = NO;
#endif
    [GVUserDefaults standardUserDefaults].isRelease = !isDebug;
    NSLog(@"Environment: %@", isDebug ? @"Debug" : @"Release");
    
    // IDs
    NSString *shortIdInLaunchOptions = [self shortIdInLaunchOptions:launchOptions];
    self.launchedWithShortID = (shortIdInLaunchOptions != nil);
    
    // Crashlytics
    [Crashlytics startWithAPIKey:@"41644116426a80147f822825bb643b3020b0f9d3"];
    
    [NewRelicAgent startWithApplicationToken:@"AA9b45f5411736426b5fac31cce185b50d173d99ea"];
    [self configureRESTClient];
    [self checkIfLoggedIn];
	
    if (self.isLaunchedWithShortID) {
        [self performSelector:@selector(didAnswerCallWithShortId:) withObject:shortIdInLaunchOptions afterDelay:0.0f];
        [self resetBadgeIcon];
    }
    
    if ([BMEAppStoreId length] > 0) {
        [Appirater setAppId:BMEAppStoreId];
        [Appirater setDaysUntilPrompt:5];
        [Appirater setUsesUntilPrompt:2];
        [Appirater setSignificantEventsUntilPrompt:2];
        [Appirater setTimeBeforeReminding:2];
        [Appirater appLaunched:NO];
    }

#if DEVELOPMENT
    UITapGestureRecognizer *secretTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSecretTapGesture:)];
    secretTapGesture.numberOfTouchesRequired = 4;
    secretTapGesture.numberOfTapsRequired = 3;
    [self.window addGestureRecognizer:secretTapGesture];
#endif
	
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didLogIn:) name:BMEDidLogInNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didLogOut:) name:BMEDidLogOutNotification object:nil];
    
    self.window.tintColor = [UIColor lightBlueColor];
    if (isStaging || isDevelopment) {
        self.inAppTestBadgeWindow = [[InAppTestBadge alloc] initWithType:isStaging ? @"Beta" : @"Alpha"];
        [self.window makeKeyAndVisible];
        [self.window addSubview:self.inAppTestBadgeWindow];
    }
    
    // Work around changes to language identifiers in iOS 9 until MKLocalization supports this
    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:@"AppleLanguages"];
    NSString *preferedLanguage = [NSLocale preferredLanguages].firstObject;
    if (preferedLanguage) {
        NSString *shortenedPreferedLanguage = [preferedLanguage substringToIndex:2];
        [MKLocalization changeLocalizationTo:shortenedPreferedLanguage];
    }
  
    return YES;
}
							
- (void)applicationWillResignActive:(UIApplication *)application {
    
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [GVUserDefaults synchronize];
    
    // We enter the background, reset the launched with short ID state to prepare for next launch
    self.launchedWithShortID = NO;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    if ([[BMEClient sharedClient] isLoggedIn] && !self.launchedWithShortID) {
        [self checkForPendingRequestIfIconHasBadge];
    }
    [self resetBadgeIcon];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
    NSDictionary *apsInfo = [userInfo objectForKey:@"aps"];
    if (!apsInfo) {
        return;
    }
    
    id alert = [apsInfo objectForKey:@"alert"];
    if (!alert) {
        return;
    }
    
    if (application.applicationState == UIApplicationStateActive) {
        if ([alert isKindOfClass:[NSDictionary class]]) {
            NSString *shortId = [alert objectForKey:@"short_id"];;
            if (shortId) {
                if (self.callAlertView) {
                    [self.callAlertView dismissWithClickedButtonIndex:[self.callAlertView cancelButtonIndex] animated:NO];
                }
                
                NSString *actionLocKey = [alert objectForKey:@"action-loc-key"];
                NSString *locKey = [alert objectForKey:@"loc-key"];
                NSArray *locArgs = [alert objectForKey:@"loc-args"];
                NSString *name = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PUSH_REQUEST_DEFAULT_NAME, BMEAppDelegateLocalizationTable);
                if ([locArgs count] > 0) {
                    name = locArgs[0];
                }
                
                NSString *title = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PUSH_REQUEST_TITLE, BMEAppDelegateLocalizationTable);
                NSString *message = [NSString stringWithFormat:NSLocalizedString(locKey, nil), name];
                NSString *actionButton = NSLocalizedString(actionLocKey, nil);
                NSString *cancelButton = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PUSH_REQUEST_CANCEL, BMEAppDelegateLocalizationTable);
                
                [self playCallTone];
                
                __weak typeof(self) weakSelf = self;
                self.callAlertView = [[PSPDFAlertView alloc] initWithTitle:title message:message];
                [self.callAlertView addButtonWithTitle:actionButton block:^{
                    [AnalyticsManager trackEvent:AnalyticsEvent_Sighted_AttemptsToAnswerFromOpenApp withProperties:nil];
                    [weakSelf didAnswerCallWithShortId:shortId];
                    [weakSelf stopCallTone];
                }];
                [self.callAlertView setCancelButtonWithTitle:cancelButton block:^{
                    [weakSelf stopCallTone];
                    [AnalyticsManager trackEvent:AnalyticsEvent_Sighted_RefusedToAnswer withProperties:nil];
                }];
                [self.callAlertView show];
            }
        } else if ([alert isKindOfClass:[NSString class]]) {
            PSPDFAlertView *alertView = [[PSPDFAlertView alloc] initWithTitle:nil message:alert];
            [alertView setCancelButtonWithTitle:@"OK" block:nil];
            [alertView show];
        }
    } else if (application.applicationState == UIApplicationStateInactive) {
        // If the application state was inactive, this means the user pressed an action button from a notification
        if ([alert isKindOfClass:[NSDictionary class]]) {
            NSString *shortId = [alert objectForKey:@"short_id"];;
            if (shortId) {
                // The app was launched from a remote notification that contained a short ID
                [AnalyticsManager trackEvent:AnalyticsEvent_Sighted_AttemptsToAnswerFromClosedApp withProperties:nil];
                self.launchedWithShortID = YES;
                [self didAnswerCallWithShortId:shortId];
            }
        }
    }
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    NSLog(@"Did register for remote notifications");
    
    NSString *normalizedDeviceToken = BMENormalizedDeviceTokenStringWithDeviceToken(deviceToken);
    
    if (normalizedDeviceToken.length == 0) {
        NSLog(@"Device token (%@) not valid, don't send to server.", normalizedDeviceToken);
        return;
    }
    
    void(^completionHandler)(NSError *) = ^(NSError *error) {
        if (!error && normalizedDeviceToken) {
            [GVUserDefaults standardUserDefaults].deviceToken = normalizedDeviceToken;
            [GVUserDefaults synchronize];
        }
    };
    
    // Update using existing device token
    [[BMEClient sharedClient] upsertDeviceWithNewToken:normalizedDeviceToken production:[GVUserDefaults standardUserDefaults].isRelease completion:^(BOOL success, NSError *error) {
        completionHandler(error);
        
        if (error) {
            NSLog(@"Failed upsert device token: %@", error);
        }
    }];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    NSLog(@"Failed registering for remote notifications: %@", error);
    [GVUserDefaults standardUserDefaults].deviceToken = nil;
}

- (void)application:(UIApplication *)application didRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
    NSLog(@"Did register user notification settings");
	[[NSNotificationCenter defaultCenter] postNotificationName:BMEDidRegisterUserNotificationsNotification object:nil];
	[application registerForRemoteNotifications];
}

- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification {
	[self checkIfLocalNotificationIsFromDemoCall:notification];
}

- (void)application:(UIApplication *)application handleActionWithIdentifier:(NSString *)identifier forLocalNotification:(UILocalNotification *)notification completionHandler:(void (^)())completionHandler {
	[self checkIfLocalNotificationIsFromDemoCall:notification];
	completionHandler();
}

- (void)application:(UIApplication*)application handleActionWithIdentifier:(NSString*)identifier forRemoteNotification:(NSDictionary*)userInfo completionHandler:(void (^)())completionHandler {

    if ([identifier isEqualToString:NotificationActionReplyYes]) {
        // Forward to regular
        [self application:application didReceiveRemoteNotification:userInfo];
    }

    if (completionHandler) {
        completionHandler();
    }
}


#pragma mark -
#pragma mark Private Methods

- (void)configureRESTClient {
    [[BMEClient sharedClient] setUsername:BMEAPIUsername password:BMEAPIPassword];
    [BMEClient sharedClient].facebookAppId = BMEFacebookAppId;
}

- (void)checkIfLoggedIn {
    NSLog(@"Check if logged in");
    if ([BMEClient sharedClient].token) {
        NSLog(@"Has auth token");
        if ([BMEClient sharedClient].isTokenValid) {
            NSLog(@"Auth token is valid");
            [self didLogin];
        } else {
            NSLog(@"Auth token not valid");
            // TODO: If auth token expiried, ask user to login.
            [self loginFailed];
        }
    } else {
        NSLog(@"No user");
        [self showFrontPage];
    }
    
    [AnalyticsManager identifyUser:[BMEClient sharedClient].currentUser];
}

- (void)loginFailed {
    [self showFrontPage];
    
    [[BMEClient sharedClient] logoutWithCompletion:nil];
    [[BMEClient sharedClient] resetLogin];
    [self resetBadgeIcon];
}

- (void)didLogin {
    [self showLoggedInMainView];
    
    [[BMEClient sharedClient] updateUserInfoWithUTCOffset:nil];
    [[BMEClient sharedClient] upsertDeviceWithNewToken:nil production:[GVUserDefaults standardUserDefaults].isRelease completion:nil];
    
    if (!self.isLaunchedWithShortID) {
        [self checkForPendingRequestIfIconHasBadge];
    }
}

- (NSString *)shortIdInLaunchOptions:(NSDictionary *)launchOptions {
    NSDictionary *userInfo = [launchOptions valueForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
    NSDictionary *apsInfo = [userInfo objectForKey:@"aps"];
    NSDictionary *alertInfo = [apsInfo objectForKey:@"alert"];
    return [alertInfo objectForKey:@"short_id"];
}

- (void)checkIfLocalNotificationIsFromDemoCall:(UILocalNotification *)notification {
	if ([[notification.userInfo objectForKey:[DemoCallViewController NotificationIsDemoKey]] boolValue]) {
		self.launchedFromDemoCall = YES;
		[[NSNotificationCenter defaultCenter] postNotificationName:BMEDidAnswerDemoCallNotification object:nil];
	}
}

- (void)didAnswerCallWithShortId:(NSString *)shortId {
    [BMEAccessControlHandler requireMicrophoneEnabled:^(BOOL isEnabled) {
        if (isEnabled) {
            BMECallViewController *callController = [self.window.rootViewController.storyboard instantiateViewControllerWithIdentifier:BMECallControllerIdentifier];
            callController.callMode = BMECallModeAnswer;
            callController.shortId = shortId;
            
            UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:callController];
            navigationController.navigationBarHidden = YES;
            
            UIViewController *presentFromController = self.window.rootViewController;
            while (presentFromController.presentedViewController) {
                presentFromController = presentFromController.presentedViewController;
            }
            
            [presentFromController presentViewController:navigationController animated:YES completion:nil];
        }
    }];
}

- (void)presentSecretSettings {
    UIViewController *secretSettingsController = [self.window.rootViewController.storyboard instantiateViewControllerWithIdentifier:BMESecretSettingsControllerIdentifier];
    
    UIViewController *presentFromController = self.window.rootViewController;
    if (presentFromController.presentedViewController) {
        presentFromController = presentFromController.presentedViewController;
    }
    
    [presentFromController presentViewController:secretSettingsController animated:YES completion:nil];
}

- (void)handleSecretTapGesture:(UITapGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        [self presentSecretSettings];
    }
}

- (void)playCallTone {
    if (!self.callAudioPlayer) {
        NSError *error = nil;
        self.callAudioPlayer = [BMECallAudioPlayer playerWithError:&error];
        if (!error) {
            if ([self.callAudioPlayer prepareToPlay]) {
                [self.callAudioPlayer play];
            }
        }
    }
}

- (void)stopCallTone {
    if (self.callAudioPlayer) {
        [self.callAudioPlayer stop];
        self.callAudioPlayer = nil;
    }
}

- (void)resetBadgeIcon {
    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
}

- (void)checkForPendingRequestIfIconHasBadge {
    NSUInteger badgeCount = [UIApplication sharedApplication].applicationIconBadgeNumber;
    if (badgeCount > 0 && !self.isLaunchedFromDemoCall) {
        MRProgressOverlayView *progressOverlayView = [MRProgressOverlayView showOverlayAddedTo:self.window animated:YES];
        progressOverlayView.mode = MRProgressOverlayViewModeIndeterminate;
        progressOverlayView.titleLabelText = MKLocalizedFromTable(BME_APP_DELEGATE_OVERLAY_LOADING_PENDING_REQUEST_TITLE, BMEAppDelegateLocalizationTable);
    
        [[BMEClient sharedClient] checkForPendingRequest:^(id shortId, BOOL success, NSError *error) {
            [progressOverlayView hide:YES];
            
            if (!success) {
                NSLog(@"Could not load pending request: %@", error);
                
                NSString *title = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PENDING_REQUEST_NOT_LOADED_TITLE, BMEAppDelegateLocalizationTable);
                NSString *message = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PENDING_REQUEST_NOT_LOADED_MESSAGE, BMEAppDelegateLocalizationTable);
                NSString *cancelButton = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PENDING_REQUEST_NOT_LOADED_CANCEL, BMEAppDelegateLocalizationTable);
                UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:cancelButton otherButtonTitles:nil, nil];
                [alertView show];
                return;
            }
            if (!shortId) {
                NSString *title = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PENDING_REQUEST_HANDLED_TITLE, BMEAppDelegateLocalizationTable);
                NSString *message = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PENDING_REQUEST_HANDLED_MESSAGE, BMEAppDelegateLocalizationTable);
                NSString *cancelButton = MKLocalizedFromTable(BME_APP_DELEGATE_ALERT_PENDING_REQUEST_HANDLED_CANCEL, BMEAppDelegateLocalizationTable);
                UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:cancelButton otherButtonTitles:nil, nil];
                [alertView show];
                return;
            }
            [self didAnswerCallWithShortId:shortId];
        }];
    }
}

- (void)didLogOut:(NSNotification *)notification {
    [self showFrontPage];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BMEGoToLoginIfPossibleNotification object:nil];
    });
    [self resetBadgeIcon];
}

- (void)didLogIn:(NSNotification *)notification {
    [self showLoggedInMainView];
    [self resetBadgeIcon];
    
    NSLog(@"DID LOG IN");
    NSLog(@"%@", notification.userInfo);
    
    NSNumber *displayHelperWelcome = [notification.userInfo objectForKey:BMEDidLogInNotificationDisplayHelperWelcomeKey];
    if (displayHelperWelcome && [displayHelperWelcome boolValue]) {
        NSLog(@"Show helper welcome");
        [self showHelperWelcomeView];
    }
}

- (void)showFrontPage {
    if ([self.window.rootViewController.restorationIdentifier isEqualToString:BMEFrontPageNavigationControllerIdentifier]) {
        BMETopNavigationController *initialViewController = (BMETopNavigationController *)self.window.rootViewController;
        if (initialViewController.presentedViewController) {
            [initialViewController dismissViewControllerAnimated:YES completion:nil];
        }
        [initialViewController popToRootViewControllerAnimated:YES];
        return;
    }
    [self setTopViewController:[self.storyboard instantiateViewControllerWithIdentifier:BMEFrontPageNavigationControllerIdentifier]];
}

- (void)showLoggedInMainView {
    if ([self.window.rootViewController.restorationIdentifier isEqualToString:BMEMainNavigationControllerIdentifier]) {
        return;
    }
    [self setTopViewController:[self.storyboard instantiateViewControllerWithIdentifier:BMEMainNavigationControllerIdentifier]];
}

- (void)showHelperWelcomeView {
    UIViewController *controller = [self.window.rootViewController.storyboard instantiateViewControllerWithIdentifier:BMEHelperWelcomeViewController];
    [self.window.rootViewController presentViewController:controller animated:YES completion:nil];
}

- (void)setTopViewController:(UIViewController *)viewController {
    for (UIView *view in self.window.subviews) { // Clear out, since presentedViewController might not be removed when settings window.rootViewController
        [view removeFromSuperview];
    }
    self.window.rootViewController = viewController;
}

- (UIStoryboard *)storyboard {
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    return storyboard;
}

@end
