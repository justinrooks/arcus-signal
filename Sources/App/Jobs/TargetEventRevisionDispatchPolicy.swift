enum TargetEventRevisionDispatchPolicy {
    static func shouldDispatchOnCreate(isExpired: Bool) -> Bool {
        isExpired == false
    }

    static func shouldDispatchOnUpdate(contentChanged: Bool, isExpired: Bool) -> Bool {
        contentChanged && isExpired == false
    }
}
