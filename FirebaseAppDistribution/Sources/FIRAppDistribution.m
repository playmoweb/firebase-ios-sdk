// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "FIRAppDistribution+Private.h"
#import "FIRAppDistributionRelease+Private.h"
#import "FIRAppDistributionMachO+Private.h"
#import "FIRAppDistributionAuthPersistence+Private.h"

#import <FirebaseCore/FIRAppInternal.h>
#import <FirebaseCore/FIRComponent.h>
#import <FirebaseCore/FIRComponentContainer.h>
#import <FirebaseCore/FIROptions.h>

#import <GoogleUtilities/GULAppDelegateSwizzler.h>
#import "FIRAppDistributionAppDelegateInterceptor.h"

/// Empty protocol to register with FirebaseCore's component system.
@protocol FIRAppDistributionInstanceProvider <NSObject>
@end

@interface FIRAppDistribution () <FIRLibrary, FIRAppDistributionInstanceProvider>
@property(nonatomic) BOOL isTesterSignedIn;
@end


NSString *const FIRAppDistributionErrorDomain = @"com.firebase.appdistribution";
NSString *const FIRAppDistributionErrorDetailsKey = @"details";

@implementation FIRAppDistribution

// The OAuth scope needed to authorize the App Distribution Tester API
NSString *const kOIDScopeTesterAPI = @"https://www.googleapis.com/auth/cloud-platform";

// The App Distribution Tester API endpoint used to retrieve releases
NSString *const kReleasesEndpointURL =
    @"https://firebaseapptesters.googleapis.com/v1alpha/devices/-/testerApps/%@/releases";
NSString *const kTesterAPIClientID =
    @"319754533822-osu3v3hcci24umq6diathdm0dipds1fb.apps.googleusercontent.com";
NSString *const kIssuerURL = @"https://accounts.google.com";
NSString *const kAppDistroLibraryName = @"fire-fad";

NSString *const kReleasesKey = @"releases";
NSString *const kLatestReleaseKey = @"latest";
NSString *const kCodeHashKey = @"codeHash";

NSString *const kAuthErrorMessage = @"Unable to authenticate the tester";

#pragma mark - Singleton Support

- (instancetype)initWithApp:(FIRApp *)app appInfo:(NSDictionary *)appInfo {
  self = [super init];

  if (self) {
    self.safariHostingViewController = [[UIViewController alloc] init];

    [GULAppDelegateSwizzler proxyOriginalDelegate];

    FIRAppDistributionAppDelegatorInterceptor *interceptor =
        [FIRAppDistributionAppDelegatorInterceptor sharedInstance];
    [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  }

  self.authState = [FIRAppDistributionAuthPersistence retrieveAuthState];
  self.isTesterSignedIn = self.authState ? YES : NO;
  return self;
}

+ (void)load {
  NSString *version =
      [NSString stringWithUTF8String:(const char *const)STR_EXPAND(FIRAppDistribution_VERSION)];
  [FIRApp registerInternalLibrary:(Class<FIRLibrary>)self
                         withName:kAppDistroLibraryName
                      withVersion:version];
}

+ (NSArray<FIRComponent *> *)componentsToRegister {
  FIRComponentCreationBlock creationBlock =
      ^id _Nullable(FIRComponentContainer *container, BOOL *isCacheable) {
    if (!container.app.isDefaultApp) {
      // TODO: Remove this and log error
      @throw([NSException exceptionWithName:@"NotImplementedException"
                                     reason:@"This code path is not implemented yet"
                                   userInfo:nil]);
      return nil;
    }

    *isCacheable = YES;

    return [[FIRAppDistribution alloc] initWithApp:container.app
                                           appInfo:NSBundle.mainBundle.infoDictionary];
  };

  FIRComponent *component =
      [FIRComponent componentWithProtocol:@protocol(FIRAppDistributionInstanceProvider)
                      instantiationTiming:FIRInstantiationTimingEagerInDefaultApp
                             dependencies:@[]
                            creationBlock:creationBlock];
  return @[ component ];
}

+ (instancetype)appDistribution {
  // The container will return the same instance since isCacheable is set

  FIRApp *defaultApp = [FIRApp defaultApp];  // Missing configure will be logged here.

  // Get the instance from the `FIRApp`'s container. This will create a new instance the
  // first time it is called, and since `isCacheable` is set in the component creation
  // block, it will return the existing instance on subsequent calls.
  id<FIRAppDistributionInstanceProvider> instance =
      FIR_COMPONENT(FIRAppDistributionInstanceProvider, defaultApp.container);

  // In the component creation block, we return an instance of `FIRAppDistribution`. Cast it and
  // return it.
  return (FIRAppDistribution *)instance;
}

- (void)signInTesterWithCompletion:(void (^)(NSError *_Nullable error))completion {
  NSURL *issuer = [NSURL URLWithString:kIssuerURL];

  [OIDAuthorizationService
      discoverServiceConfigurationForIssuer:issuer
                                 completion:^(OIDServiceConfiguration *_Nullable configuration,
                                              NSError *_Nullable error) {
                                   [self handleOauthDiscoveryCompletion:configuration
                                                                  error:error
                                        appDistributionSignInCompletion:completion];
                                 }];
}

- (void)signOutTester {
  [FIRAppDistributionAuthPersistence clearAuthState];
  self.authState = nil;
  self.isTesterSignedIn = false;
}

- (NSError *)NSErrorForErrorCodeAndMessage:(FIRAppDistributionError)errorCode
                                   message:(NSString *)message {
    NSDictionary *userInfo = @{FIRAppDistributionErrorDetailsKey : message};
    return [NSError errorWithDomain:FIRAppDistributionErrorDomain code:errorCode userInfo:userInfo];
}

- (void)fetchReleases:(FIRAppDistributionUpdateCheckCompletion)completion {

    [self.authState performActionWithFreshTokens:^(NSString *_Nonnull accessToken,
                                               NSString *_Nonnull idToken,
                                               NSError *_Nullable error) {
      if (error) {
          // Error fetching fresh tokens
          // TODO: Do we need a less aggresive strategy here? maybe a retry?
          [self signOutTester];
          NSError *HTTPError = [self NSErrorForErrorCodeAndMessage:FIRAppDistributionErrorAuthenticationFailure
                                    message:kAuthErrorMessage];
          
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, HTTPError);
        });
          
        return;
      }

      // perform your API request using the tokens
        NSURLSession *URLSession = [NSURLSession sharedSession];
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
        NSString *URLString =
            [NSString stringWithFormat:kReleasesEndpointURL, [[FIRApp defaultApp] options].googleAppID];
        [request setURL:[NSURL URLWithString:URLString]];
        [request setHTTPMethod:@"GET"];
        [request setValue:[NSString
                              stringWithFormat:@"Bearer %@", accessToken]
            forHTTPHeaderField:@"Authorization"];

        NSURLSessionDataTask *listReleasesDataTask = [URLSession
            dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;
                if (error || HTTPResponse.statusCode != 200) {
                    NSError *HTTPError = nil;
                    if(HTTPResponse == nil && error) {
                        // Handles network timeouts or no internet connectivity
                        NSString *message = error.userInfo[NSLocalizedDescriptionKey] ? error.userInfo[NSLocalizedDescriptionKey] : @"";
                        
                        HTTPError = [self NSErrorForErrorCodeAndMessage:FIRAppDistributionErrorNetworkFailure               message:message];
                    }
                    else if(HTTPResponse.statusCode == 401) {
                        // TODO: Maybe sign out tester?
                        HTTPError = [self NSErrorForErrorCodeAndMessage:FIRAppDistributionErrorAuthenticationFailure
                                                            message:kAuthErrorMessage];
                    } else {
                        HTTPError = [self NSErrorForErrorCodeAndMessage:FIRAppDistributionErrorUnknown
                                                            message:@""];
                    }
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(nil, HTTPError);
                    });
                  
                } else {
                    [self handleReleasesAPIResponseWithData:data completion:completion];
                }
            }];

        [listReleasesDataTask resume];
    }];
}

- (void)handleOauthDiscoveryCompletion:(OIDServiceConfiguration *_Nullable)configuration
                                 error:(NSError *_Nullable)error
       appDistributionSignInCompletion:(void (^)(NSError *_Nullable error))completion {
  if (!configuration) {
    // TODO: Handle when we cannot get configuration
      NSLog(@"ERROR - Cannot discover oauth config");
    @throw([NSException exceptionWithName:@"NotImplementedException"
                                   reason:@"This code path is not implemented yet"
                                 userInfo:nil]);
    return;
  }

  NSString *redirectURL = [@"dev.firebase.appdistribution."
      stringByAppendingString:[[[NSBundle mainBundle] bundleIdentifier]
                                  stringByAppendingString:@":/launch"]];

  OIDAuthorizationRequest *request = [[OIDAuthorizationRequest alloc]
      initWithConfiguration:configuration
                   clientId:kTesterAPIClientID
                     scopes:@[ OIDScopeOpenID, OIDScopeProfile, kOIDScopeTesterAPI ]
                redirectURL:[NSURL URLWithString:redirectURL]
               responseType:OIDResponseTypeCode
       additionalParameters:nil];

  [self createUIWindowForLogin];
  // performs authentication request
  [FIRAppDistributionAppDelegatorInterceptor sharedInstance].currentAuthorizationFlow =
      [OIDAuthState authStateByPresentingAuthorizationRequest:request
                                     presentingViewController:self.safariHostingViewController
                                                     callback:^(OIDAuthState *_Nullable authState,
                                                                NSError *_Nullable error) {
          // TODO: Handle error code for user cancellation
          self.authState = authState;
          if(authState) {
              [FIRAppDistributionAuthPersistence persistAuthState:authState];
          }
          self.isTesterSignedIn = self.authState ? YES : NO;
          completion(error);
        }];
}


- (UIWindow *)createUIWindowForLogin {
  // Create an empty window + viewController to host the Safari UI.
  UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  window.rootViewController = self.safariHostingViewController;

  // Place it at the highest level within the stack.
  window.windowLevel = +CGFLOAT_MAX;

  // Run it.
  [window makeKeyAndVisible];

  return window;
}

- (void)handleReleasesAPIResponseWithData:data
                               completion:(FIRAppDistributionUpdateCheckCompletion)completion {
  NSError *error = nil;
  NSDictionary *serializedResponse = [NSJSONSerialization
                          JSONObjectWithData:data
                          options:0
                          error:&error];

    NSArray *releaseList = [serializedResponse objectForKey:kReleasesKey];
    for (NSDictionary *releaseDict in releaseList) {
        if([[releaseDict objectForKey:kLatestReleaseKey] boolValue]) {
            NSString *codeHash = [releaseDict objectForKey:kCodeHashKey];
            NSString *executablePath = [[NSBundle mainBundle] executablePath];
            FIRAppDistributionMachO *machO = [[FIRAppDistributionMachO alloc] initWithPath:executablePath];

            if(codeHash && ![codeHash isEqualToString:machO.codeHash]) {
                FIRAppDistributionRelease *release = [[FIRAppDistributionRelease alloc] initWithDictionary:releaseDict];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(release, nil);
                });
                
                return;
            }

            break;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, nil);
    });
}
- (void)checkForUpdateWithCompletion:(FIRAppDistributionUpdateCheckCompletion)completion {
  if (self.isTesterSignedIn) {
    [self fetchReleases:completion];
  } else {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Enable in-app alerts"
                         message:@"Sign in with your Firebase App Distribution Google account to "
                                 @"turn on in-app alerts for new test releases."
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *yesButton =
        [UIAlertAction actionWithTitle:@"Turn on"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 [self signInTesterWithCompletion:^(NSError *_Nullable error) {
                                   self.window.hidden = YES;
                                   self.window = nil;

                                   if (error) {
                                     completion(nil, error);
                                     return;
                                   }

                                   [self fetchReleases:completion];
                                 }];
                               }];

    UIAlertAction *noButton = [UIAlertAction actionWithTitle:@"Not now"
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
                                                       // precaution to ensure window gets destroyed
                                                       self.window.hidden = YES;
                                                       self.window = nil;
                                                       completion(nil, nil);
                                                     }];

    [alert addAction:noButton];
    [alert addAction:yesButton];

    // Create an empty window + viewController to host the Safari UI.
    self.window = [self createUIWindowForLogin];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
  }
}
@end
