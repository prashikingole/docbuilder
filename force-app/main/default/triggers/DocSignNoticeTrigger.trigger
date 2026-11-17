trigger DocSignNoticeTrigger on DocSignNotice__e(after insert) {
    DocBuilderSignNotices.handle(Trigger.new);
}
