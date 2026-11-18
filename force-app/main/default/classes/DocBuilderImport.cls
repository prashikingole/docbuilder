/**
 * Matches the merge fields of an imported template to Salesforce fields, so a template brought over from
 * Word, Conga Composer, DocuSign Gen, Salesforce CPQ or plain HTML does not have to be rebuilt by hand.
 *
 * Understands the usual naming styles:
 *   Opportunity.Account.Name, Account.Name, quote.SBQQ__Account__r.Name   (dotted paths, with or without a root)
 *   OPPORTUNITY_ACCOUNT_NAME, ACCOUNT_BILLINGCITY                         (Conga-style underscore names)
 *   Close Date, Billing City                                              (field labels)
 * A name matches a field's API name first, then its label, ignoring case, spaces, punctuation, namespace
 * prefixes and the __c / __r suffixes. Related records are followed up to two levels.
 *
 * Only object descriptions are read, limited to fields the current user can see. No records are read or written.
 */
public with sharing class DocBuilderImport {
    static final Set<String> GENERIC_ROOTS = new Set<String>{ 'template', 'record', 'this', 'object', 'line', 'lines', 'lineitem', 'item', 'row', 'current' };
    static final Integer MAX_TOKENS = 500;
    static final Integer MAX_DEPTH = 2;

    final Map<String, ObjectIndex> indexes = new Map<String, ObjectIndex>();

    class ObjectIndex {
        String simpleName;
        String simpleLabel;
        // Simplified API name or label -> field API name. API names are added first so they win over labels.
        Map<String, String> fields = new Map<String, String>();
        // Simplified relationship name or lookup label -> the lookup field.
        Map<String, Schema.DescribeFieldResult> lookups = new Map<String, Schema.DescribeFieldResult>();
    }

    /** Lower case letters and digits only, without a namespace prefix or the __c / __r / __e suffix. */
    public static String simplify(String value) {
        if (value == null) {
            return '';
        }
        String s = value.trim();
        // A namespace prefix needs a second double underscore after it: SBQQ__Quote__c, not Discount__c.
        if (Pattern.matches('[A-Za-z][A-Za-z0-9]*__[A-Za-z].*__[a-zA-Z]+', s)) {
            s = s.substringAfter('__');
        }
        s = s.replaceAll('__(c|r|e|mdt)$', '');
        return s.toLowerCase().replaceAll('[^a-z0-9]', '');
    }

    /** The token as written, without Word field switches, format hints or marker characters. */
    public static String cleanToken(String token) {
        String s = token == null ? '' : token.trim();
        // Word field switches: MERGEFIELD Name \* MERGEFORMAT
        if (s.contains('\\')) {
            s = s.substringBefore('\\').trim();
        }
        // Format hints: {{Amount|currency}} or {!Amount:currency}
        if (s.contains('|')) {
            s = s.substringBefore('|').trim();
        }
        s = s.removeStart('!').removeStart('$').trim();
        return s.replaceAll('\\s+', ' ');
    }

    ObjectIndex indexOf(String objectName) {
        if (String.isBlank(objectName)) {
            return null;
        }
        String key = objectName.toLowerCase();
        if (indexes.containsKey(key)) {
            return indexes.get(key);
        }
        ObjectIndex idx;
        try {
            Schema.DescribeSObjectResult d = Schema.describeSObjects(new List<String>{ objectName })[0];
            idx = new ObjectIndex();
            idx.simpleName = simplify(d.getName());
            idx.simpleLabel = simplify(d.getLabel());
            List<Schema.DescribeFieldResult> readable = new List<Schema.DescribeFieldResult>();
            for (Schema.SObjectField f : d.fields.getMap().values()) {
                Schema.DescribeFieldResult fd = f.getDescribe();
                if (fd.isAccessible()) {
                    readable.add(fd);
                }
            }
            for (Schema.DescribeFieldResult fd : readable) {
                idx.fields.put(simplify(fd.getName()), fd.getName());
                if (fd.getType() == Schema.DisplayType.REFERENCE && fd.getRelationshipName() != null && !fd.getReferenceTo().isEmpty()) {
                    idx.lookups.put(simplify(fd.getRelationshipName()), fd);
                }
            }
            for (Schema.DescribeFieldResult fd : readable) {
                String label = simplify(fd.getLabel());
                if (!idx.fields.containsKey(label)) {
                    idx.fields.put(label, fd.getName());
                }
                if (fd.getType() == Schema.DisplayType.REFERENCE && fd.getRelationshipName() != null && !fd.getReferenceTo().isEmpty()) {
                    String lookupLabel = simplify(fd.getLabel().removeEnd(' ID').removeEnd(' Id'));
                    if (!idx.lookups.containsKey(lookupLabel)) {
                        idx.lookups.put(lookupLabel, fd);
                    }
                }
            }
        } catch (Exception e) {
            idx = null;
        }
        indexes.put(key, idx);
        return idx;
    }

    Boolean isRoot(String part, ObjectIndex idx, Set<String> extraRoots) {
        String s = simplify(part);
        return s == idx.simpleName || s == idx.simpleLabel || GENERIC_ROOTS.contains(s) || extraRoots.contains(s);
    }

    /** The field path for one token on the given object, or null when nothing fits. */
    public String resolve(String objectName, String token, Set<String> extraRoots) {
        ObjectIndex idx = indexOf(objectName);
        String clean = cleanToken(token);
        if (idx == null || String.isBlank(clean)) {
            return null;
        }
        List<String> parts = clean.split('\\.');
        while (parts.size() > 1 && isRoot(parts[0], idx, extraRoots)) {
            parts.remove(0);
        }
        String found = walk(idx, parts, 0, extraRoots);
        if (found == null && parts.size() == 1 && clean.contains(' ')) {
            // A label typed with spaces, e.g. "Close Date".
            found = idx.fields.get(simplify(clean));
        }
        return found;
    }

    String walk(ObjectIndex idx, List<String> parts, Integer depth, Set<String> extraRoots) {
        if (idx == null || parts.isEmpty() || depth > MAX_DEPTH) {
            return null;
        }
        if (parts.size() > 1) {
            Schema.DescribeFieldResult lookup = idx.lookups.get(simplify(parts[0]));
            if (lookup == null) {
                return null;
            }
            List<String> rest = parts.clone();
            rest.remove(0);
            String nested = walk(indexOf(String.valueOf(lookup.getReferenceTo()[0])), rest, depth + 1, new Set<String>());
            return nested == null ? null : lookup.getRelationshipName() + '.' + nested;
        }
        String one = parts[0];
        String api = idx.fields.get(simplify(one));
        if (api != null) {
            return api;
        }
        // Underscore-joined names, e.g. OPPORTUNITY_ACCOUNT_NAME: try each split into "record" and "field".
        List<String> words = one.split('_');
        for (Integer cut = 1; cut < words.size(); cut++) {
            List<String> leftWords = new List<String>();
            List<String> rightWords = new List<String>();
            for (Integer i = 0; i < words.size(); i++) {
                if (i < cut) {
                    leftWords.add(words[i]);
                } else {
                    rightWords.add(words[i]);
                }
            }
            String left = simplify(String.join(leftWords, '_'));
            String right = String.join(rightWords, '_');
            if (String.isBlank(left) || String.isBlank(right)) {
                continue;
            }
            if (left == idx.simpleName || left == idx.simpleLabel || GENERIC_ROOTS.contains(left) || extraRoots.contains(left)) {
                String own = walk(idx, new List<String>{ right }, depth, new Set<String>());
                if (own != null) {
                    return own;
                }
            }
            Schema.DescribeFieldResult lookup = idx.lookups.get(left);
            if (lookup != null && depth < MAX_DEPTH) {
                String nested = walk(indexOf(String.valueOf(lookup.getReferenceTo()[0])), new List<String>{ right }, depth + 1, new Set<String>());
                if (nested != null) {
                    return lookup.getRelationshipName() + '.' + nested;
                }
            }
        }
        return null;
    }

    /**
     * Suggested field path for each token (missing when nothing fits). listName is the related list a table's
     * row repeats over, so tokens such as QuoteLineItems.Quantity or LineItems_Quantity match the row's own fields.
     */
    public Map<String, String> suggest(String objectName, List<String> tokens, String listName) {
        Map<String, String> result = new Map<String, String>();
        if (tokens == null) {
            return result;
        }
        Set<String> extraRoots = new Set<String>();
        if (String.isNotBlank(listName)) {
            extraRoots.add(simplify(listName));
            // Conga and CPQ often shorten list names: QuoteLineItems -> LineItems.
            String shorter = simplify(listName).replaceFirst('^(quote|opportunity|order|contract|invoice)', '');
            if (String.isNotBlank(shorter)) {
                extraRoots.add(shorter);
            }
        }
        Integer count = 0;
        for (String token : tokens) {
            if (String.isBlank(token) || result.containsKey(token)) {
                continue;
            }
            if (++count > MAX_TOKENS) {
                break;
            }
            String path = resolve(objectName, token, extraRoots);
            if (path != null) {
                result.put(token, path);
            }
        }
        return result;
    }
}
