/**
 * Post-install script, named in sfdx-project.json (postInstallScript). Runs on every install and upgrade.
 *
 * Starts the 15-minute signature status check, so admins do not have to run Apex after installing.
 * It never fails the install: if scheduling is not possible, the admin can still start the check
 * from Anonymous Apex with DocBuilderSignSync.schedule();
 *
 * Secrets cannot be set here. The Dropbox Sign API key belongs to each customer, so it is added
 * after install on the DocBuilder Dropbox Sign external credential.
 */
global with sharing class DocBuilderInstall implements InstallHandler {
    @TestVisible
    static String lastError;
    @TestVisible
    static Boolean simulateFailure = false;

    global void onInstall(InstallContext context) {
        try {
            if (simulateFailure) {
                throw new DocBuilder.DocBuilderException('Simulated scheduling failure');
            }
            if (!DocBuilderSignSync.isScheduled()) {
                DocBuilderSignSync.schedule();
            }
        } catch (Exception e) {
            lastError = e.getMessage();
        }
    }
}
