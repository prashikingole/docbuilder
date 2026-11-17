@IsTest
private class DocBuilderInstallTest {
    @IsTest
    static void newInstallStartsTheStatusCheck() {
        DocBuilderSignSync.unschedule();
        Test.startTest();
        Test.testInstall(new DocBuilderInstall(), null);
        Test.stopTest();
        System.assert(DocBuilderSignSync.isScheduled(), 'Install should start the signature status check. ' + DocBuilderInstall.lastError);
        System.assertEquals(4, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'DocBuilder signature status%']);
    }

    @IsTest
    static void upgradeKeepsTheExistingScheduleWithoutDuplicates() {
        DocBuilderSignSync.schedule();
        Test.startTest();
        Test.testInstall(new DocBuilderInstall(), new Version(1, 0), true);
        Test.stopTest();
        System.assertEquals(4, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'DocBuilder signature status%']);
        System.assertEquals(null, DocBuilderInstall.lastError);
    }

    @IsTest
    static void aSchedulingProblemNeverFailsTheInstall() {
        DocBuilderInstall.simulateFailure = true;
        Test.testInstall(new DocBuilderInstall(), null);
        System.assertEquals('Simulated scheduling failure', DocBuilderInstall.lastError);
    }
}
