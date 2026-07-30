import Vapor

func installAPIRequestDependencies(on application: Application) {
    let previewProvider: any AnvilProfilePreviewProviding
    if let configuredProvider = application.configuredAnvilProfilePreviewProvider {
        previewProvider = configuredProvider
    } else {
        let defaultProvider = DefaultAnvilProfilePreviewProvider(application: application)
        application.anvilProfilePreviewProvider = defaultProvider
        previewProvider = defaultProvider
    }

    let analysisProvider: any AnvilProfileAnalysisProviding
    if let configuredProvider = application.configuredAnvilProfileAnalysisProvider {
        analysisProvider = configuredProvider
    } else {
        let defaultProvider = DefaultAnvilProfileAnalysisProvider(
            application: application,
            previewProvider: previewProvider
        )
        application.anvilProfileAnalysisProvider = defaultProvider
        analysisProvider = defaultProvider
    }

    if application.configuredStormSetupProvider == nil {
        application.stormSetupProvider = DefaultStormSetupProvider(
            application: application,
            anvilProfileAnalysisProvider: analysisProvider
        )
    }
}
