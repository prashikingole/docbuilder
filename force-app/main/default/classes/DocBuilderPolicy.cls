/**
 * Organization rules for actions that send data out of Salesforce or use a lot of resources:
 * who may email documents and to whom, and who may run bulk generation and how large.
 * Limits come from the DocBuilder Settings custom setting.
 */
public with sharing class DocBuilderPolicy {
    public static final String EMAIL_PERMISSION = 'DocBuilder_Send_Email';
    public static final String BULK_PERMISSION = 'DocBuilder_Bulk_Generate';
    static final Integer DEFAULT_MAX_RECIPIENTS = 10;
    static final Integer DEFAULT_MAX_BULK = 2000;
    static final Pattern EMAIL = Pattern.compile('^[A-Za-z0-9._%+\'-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}$');

    static DocBuilderSettings__c settings() {
        DocBuilderSettings__c row = DocBuilderSettings__c.getInstance();
        return row == null ? new DocBuilderSettings__c() : row;
    }

    public static Boolean canEmail() {
        return FeatureManagement.checkPermission(EMAIL_PERMISSION);
    }

    public static Boolean canBulk() {
        return FeatureManagement.checkPermission(BULK_PERMISSION);
    }

    /** Validates recipients against the org's rules and returns them cleaned up. Throws with a plain explanation if any rule is broken. */
    public static List<String> checkRecipients(List<String> recipients) {
        if (!canEmail()) {
            throw new DocBuilder.DocBuilderException('You do not have permission to email documents. Ask an administrator for the DocBuilder Email Sender permission set.');
        }
        List<String> cleaned = new List<String>();
        for (String address : recipients) {
            if (String.isNotBlank(address)) {
                cleaned.add(address.trim().toLowerCase());
            }
        }
        DocBuilderSettings__c row = settings();
        Integer maxRecipients = row.Max_Email_Recipients__c == null ? DEFAULT_MAX_RECIPIENTS : row.Max_Email_Recipients__c.intValue();
        if (cleaned.size() > maxRecipients) {
            throw new DocBuilder.DocBuilderException('A document can be emailed to at most ' + maxRecipients + ' recipients.');
        }
        Set<String> domains = new Set<String>();
        if (String.isNotBlank(row.Allowed_Email_Domains__c)) {
            for (String domain : row.Allowed_Email_Domains__c.split(',')) {
                if (String.isNotBlank(domain)) {
                    domains.add(domain.trim().toLowerCase().removeStart('@'));
                }
            }
        }
        for (String address : cleaned) {
            if (!EMAIL.matcher(address).matches()) {
                throw new DocBuilder.DocBuilderException('"' + address.left(80) + '" is not a valid email address.');
            }
            if (!domains.isEmpty() && !domains.contains(address.substringAfter('@'))) {
                throw new DocBuilder.DocBuilderException('Documents can only be emailed to these domains: ' + String.join(new List<String>(domains), ', ') + '.');
            }
        }
        return cleaned;
    }

    /** The org-wide address documents are sent from, or null to send as the user. */
    public static Id senderAddressId() {
        String address = settings().Org_Wide_Email__c;
        if (String.isBlank(address)) {
            return null;
        }
        List<OrgWideEmailAddress> found = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :address.trim() WITH SYSTEM_MODE LIMIT 1];
        return found.isEmpty() ? null : found[0].Id;
    }

    public static void checkBulk(Integer recordCount) {
        if (!canBulk()) {
            throw new DocBuilder.DocBuilderException('You do not have permission to run bulk generation. Ask an administrator for the DocBuilder Bulk Runner permission set.');
        }
        DocBuilderSettings__c row = settings();
        Integer maxRecords = row.Max_Bulk_Records__c == null ? DEFAULT_MAX_BULK : row.Max_Bulk_Records__c.intValue();
        if (recordCount > maxRecords) {
            throw new DocBuilder.DocBuilderException('A bulk run can include at most ' + maxRecords + ' records.');
        }
    }
}
