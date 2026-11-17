/**
 * Schedules the regular status check for open Signature Requests.
 * Start it once from Anonymous Apex: DocBuilderSignSync.schedule();  Stop it with DocBuilderSignSync.unschedule();
 * The work itself is done by DocBuilderSignSyncJob.
 */
global with sharing class DocBuilderSignSync implements Schedulable {
    static final String JOB_NAME = 'DocBuilder signature status';

    /** Checks every 15 minutes. */
    global static void schedule() {
        unschedule();
        for (Integer minute : new List<Integer>{ 0, 15, 30, 45 }) {
            System.schedule(JOB_NAME + ' :' + String.valueOf(minute).leftPad(2, '0'), '0 ' + minute + ' * * * ?', new DocBuilderSignSync());
        }
    }

    global static void unschedule() {
        for (CronTrigger job : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :(JOB_NAME + '%')]) {
            System.abortJob(job.Id);
        }
    }

    global static Boolean isScheduled() {
        return [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :(JOB_NAME + '%')] > 0;
    }

    global void execute(SchedulableContext context) {
        System.enqueueJob(new DocBuilderSignSyncJob(null));
    }
}
