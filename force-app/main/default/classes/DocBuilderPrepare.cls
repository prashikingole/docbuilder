/**
 * Prepares a template body before data is loaded:
 *  1. Terms blocks that name a clause category are filled from the clause library.
 *  2. Text is swapped for its translation when a language is requested.
 * Field tokens inside translated text are resolved later, exactly like the default language.
 */
public with sharing class DocBuilderPrepare {
    /** One translatable piece of text in a template. */
    public class TextPart {
        @AuraEnabled
        public String blockId;
        @AuraEnabled
        public String part;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String source;
        @AuraEnabled
        public String translated;
        @AuraEnabled
        public Boolean outOfDate = false;
    }

    class Slot {
        String blockId;
        String part;
        String label;
        Map<String, Object> target;
        String key;
        Slot(String blockId, String part, String label, Map<String, Object> target, String key) {
            this.blockId = blockId;
            this.part = part;
            this.label = label;
            this.target = target;
            this.key = key;
        }
    }

    public static void apply(Map<String, Object> body, Id versionId, String language) {
        expandClauses(body, language);
        if (String.isBlank(language) || versionId == null) {
            return;
        }
        Map<String, String> translations = new Map<String, String>();
        for (DocTranslation__c t : [
            SELECT Block_Id__c, Part__c, Translated_Text__c
            FROM DocTranslation__c
            WHERE Template_Version__c = :versionId AND Language__c = :language
        ]) {
            if (String.isNotBlank(t.Translated_Text__c)) {
                translations.put(t.Block_Id__c + '|' + t.Part__c, t.Translated_Text__c);
            }
        }
        for (Slot s : slots(body)) {
            String translated = translations.get(s.blockId + '|' + s.part);
            if (translated != null) {
                s.target.put(s.key, translated);
            }
        }
    }

    /** Lists every translatable piece of a template with its current translation, for the designer. */
    public static List<TextPart> parts(Map<String, Object> body, Id versionId, String language) {
        Map<String, DocTranslation__c> existing = new Map<String, DocTranslation__c>();
        if (versionId != null && String.isNotBlank(language)) {
            for (DocTranslation__c t : [
                SELECT Block_Id__c, Part__c, Source_Text__c, Translated_Text__c
                FROM DocTranslation__c
                WHERE Template_Version__c = :versionId AND Language__c = :language
            ]) {
                existing.put(t.Block_Id__c + '|' + t.Part__c, t);
            }
        }
        List<TextPart> result = new List<TextPart>();
        for (Slot s : slots(body)) {
            TextPart p = new TextPart();
            p.blockId = s.blockId;
            p.part = s.part;
            p.label = s.label;
            p.source = (String) s.target.get(s.key);
            DocTranslation__c t = existing.get(s.blockId + '|' + s.part);
            if (t != null) {
                p.translated = t.Translated_Text__c;
                p.outOfDate = String.isNotBlank(t.Translated_Text__c) && t.Source_Text__c != p.source;
            }
            result.add(p);
        }
        return result;
    }

    static List<Slot> slots(Map<String, Object> body) {
        List<Slot> result = new List<Slot>();
        if (body.get('page') instanceof Map<String, Object>) {
            Map<String, Object> page = (Map<String, Object>) body.get('page');
            for (String key : new List<String>{ 'header', 'footer', 'watermark' }) {
                if (page.get(key) instanceof Map<String, Object>) {
                    addSlot(result, 'page', key, 'page ' + key, (Map<String, Object>) page.get(key), 'text');
                }
            }
        }
        for (Object b : DocBuilderContext.asList(body.get('blocks'))) {
            Map<String, Object> blk = (Map<String, Object>) b;
            if (blk.get('id') == null) {
                continue;
            }
            String id = String.valueOf(blk.get('id'));
            String type = blk.get('type') == null ? 'text' : (String) blk.get('type');
            addSlot(result, id, 'text', type + ' text', blk, 'text');
            addSlot(result, id, 'elseText', type + ' fallback text', blk, 'elseText');
            addSlot(result, id, 'title', 'terms title', blk, 'title');
            Integer i = 0;
            for (Object c : DocBuilderContext.asList(blk.get('columns'))) {
                addSlot(result, id, 'col:' + i, 'column heading', (Map<String, Object>) c, 'header');
                i++;
            }
            i = 0;
            for (Object t : DocBuilderContext.asList(blk.get('totals'))) {
                addSlot(result, id, 'total:' + i, 'summary label', (Map<String, Object>) t, 'label');
                i++;
            }
            for (Object it : DocBuilderContext.asList(blk.get('items'))) {
                Map<String, Object> item = (Map<String, Object>) it;
                // Library clauses carry their own translations; only inline clauses are translated here.
                if (item.get('id') != null && item.get('clauseId') == null) {
                    addSlot(result, id, 'item:' + item.get('id'), 'clause', item, 'text');
                }
            }
        }
        return result;
    }

    static void addSlot(List<Slot> result, String blockId, String part, String label, Map<String, Object> target, String key) {
        Object value = target.get(key);
        if (value instanceof String && String.isNotBlank((String) value)) {
            result.add(new Slot(blockId, part, label, target, key));
        }
    }

    static void expandClauses(Map<String, Object> body, String language) {
        Set<String> categories = new Set<String>();
        for (Object b : DocBuilderContext.asList(body.get('blocks'))) {
            Object category = ((Map<String, Object>) b).get('clauseCategory');
            if (category != null && String.isNotBlank(String.valueOf(category))) {
                categories.add(String.valueOf(category));
            }
        }
        if (categories.isEmpty()) {
            return;
        }
        List<DocClause__c> clauses = [
            SELECT Id, Category__c, Text__c, Rule_JSON__c
            FROM DocClause__c
            WHERE Active__c = TRUE AND Category__c IN :categories
            ORDER BY Sort_Order__c NULLS LAST, Name
        ];
        Map<Id, String> translated = new Map<Id, String>();
        if (String.isNotBlank(language) && !clauses.isEmpty()) {
            for (DocTranslation__c t : [SELECT Clause__c, Translated_Text__c FROM DocTranslation__c WHERE Clause__c IN :clauses AND Language__c = :language]) {
                if (String.isNotBlank(t.Translated_Text__c)) {
                    translated.put(t.Clause__c, t.Translated_Text__c);
                }
            }
        }
        for (Object b : DocBuilderContext.asList(body.get('blocks'))) {
            Map<String, Object> blk = (Map<String, Object>) b;
            if (blk.get('clauseCategory') == null) {
                continue;
            }
            String category = String.valueOf(blk.get('clauseCategory'));
            List<Object> items = new List<Object>(DocBuilderContext.asList(blk.get('items')));
            for (DocClause__c clause : clauses) {
                if (clause.Category__c != category) {
                    continue;
                }
                Map<String, Object> item = new Map<String, Object>{
                    'id' => 'clause-' + clause.Id,
                    'clauseId' => clause.Id,
                    'text' => translated.containsKey(clause.Id) ? translated.get(clause.Id) : clause.Text__c
                };
                if (String.isNotBlank(clause.Rule_JSON__c)) {
                    item.put('showIf', JSON.deserializeUntyped(clause.Rule_JSON__c));
                }
                items.add(item);
            }
            blk.put('items', items);
        }
    }
}
