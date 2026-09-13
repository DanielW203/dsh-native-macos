// Umbrella header for the CZstd framework module.
//
// Xcode generates a framework's module map from a public header named after the
// product, so without a file called CZstd.h there is no module to import and every
// Swift consumer fails with "Unable to find module dependency: 'CZstd'". SwiftPM gets
// this for free from `publicHeadersPath`; the Xcode project has to declare it.
#import "czstd_shim.h"
