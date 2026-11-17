/**
 * Optional third interface for a signature provider: a harmless call that proves the connection works
 * (address, sign-in and permissions) without sending anything. Used by Test connection in the designer.
 * Implement it alongside DocBuilderSignProvider on the same class.
 */
global interface DocBuilderSignCheck {
    /** Returns a short description of the connected account. Throws if the connection does not work. */
    String check(DocBuilderSign.ProviderConfig config);
}
