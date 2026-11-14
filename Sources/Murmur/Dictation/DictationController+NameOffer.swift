import Foundation
import MurmurCore

extension DictationController {
    /// Shows Done with an offer to add one new name, when this dictation has one, and says whether
    /// it did (`NameOfferCoordinator`). With `FeatureFlags.personMemory` off it is always false and
    /// nothing is touched, so the caller shows Done exactly as before.
    func offerName(after presentation: DeliveryPresentation, _ dictation: NameOfferCoordinator.Dictation) -> Bool {
        nameOffers.onSaveFailed = { [weak self] message in self?.flashError(message) }
        return nameOffers.present(presentation, on: pill, for: dictation)
    }
}
