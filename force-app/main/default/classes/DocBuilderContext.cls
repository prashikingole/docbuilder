/**
 * Holds everything one generation needs: the template body, the source record with its
 * parent fields and child lists, calculated values, rule evaluation and value formatting.
 * It also records every value and rule result it touches, which becomes the audit snapshot.
 */
public with sharing class DocBuilderContext {
    static final Pattern TOKEN = Pattern.compile('\\{\\{\\s*([^}|]+?)\\s*(?:\\|\\s*([A-Za-z]+)\\s*)?\\}\\}');
    static final Pattern SAFE_PATH = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$');
    static final Pattern EXPR_IDENT = Pattern.compile('calc:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_.]*');
    static final Integer CHILD_ROW_LIMIT = 500;
    static final Integer SNAPSHOT_LIMIT = 130000;

    public String baseObject;
    public Id recordId;
    public Map<String, Object> body;
    public String fileNamePattern;
    public SObject record;
    public Map<String, List<SObject>> lists = new Map<String, List<SObject>>();
    public Map<String, Decimal> calcs = new Map<String, Decimal>();
    public Map<String, Object> usedValues = new Map<String, Object>();
    public Map<String, Object> logicLog = new Map<String, Object>();

    // Lower-cased path -> path as written, so the same field is never selected twice.
    Map<String, String> parentFields = new Map<String, String>{ 'id' => 'Id' };
    Map<String, Map<String, String>> childFields = new Map<String, Map<String, String>>();
    Map<String, String> childOrder = new Map<String, String>();
    Map<String, String> calcFormats = new Map<String, String>();
    Map<String, Map<String, Schema.SObjectField>> fieldMaps = new Map<String, Map<String, Schema.SObjectField>>();

    public DocBuilderContext(String baseObject, Id recordId, Map<String, Object> body, String fileNamePattern) {
        this.baseObject = safe(baseObject);
        this.recordId = recordId;
        this.body = body == null ? new Map<String, Object>() : body;
        this.fileNamePattern = fileNamePattern;
    }

    // ---------- Template helpers ----------

    public List<Object> blocks() {
        return asList(body.get('blocks'));
    }

    public static List<Object> asList(Object value) {
        return value == null ? new List<Object>() : (List<Object>) value;
    }

    static String safe(String path) {
        if (path == null || !SAFE_PATH.matcher(path.trim()).matches()) {
            throw new DocBuilder.DocBuilderException('"' + path + '" is not a valid field or relationship name.');
        }
        return path.trim();
    }

    // ---------- Loading ----------

    Boolean collected = false;

    public void load() {
        // USER_MODE enforces the running user's object, field and record access.
        List<SObject> rows = Database.queryWithBinds(buildSoql(), new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            throw new DocBuilder.DocBuilderException('The record could not be found or you do not have access to it.');
        }
        record = rows[0];
        for (String rel : childFields.keySet()) {
            List<SObject> kids = rel.contains('.') ? loadParentList(rel) : record.getSObjects(rel);
            lists.put(rel, kids == null ? new List<SObject>() : kids);
        }
        computeCalcs();
    }

    /** Runs the template's main query against no record, to surface missing or inaccessible fields. Returns null when valid. */
    public String check() {
        try {
            Database.queryWithBinds(buildSoql(), new Map<String, Object>{ 'recordId' => null }, AccessLevel.USER_MODE);
            return null;
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    String buildSoql() {
        if (!collected) {
            collect();
            collected = true;
        }
        for (String rel : childFields.keySet()) {
            if (rel.contains('.')) {
                // A list on a related record, e.g. Account.Contacts: we need the related record's Id first.
                addField(parentFields, rel.substringBeforeLast('.') + '.Id');
            }
        }
        List<String> selects = new List<String>(parentFields.values());
        for (String rel : childFields.keySet()) {
            if (!rel.contains('.')) {
                selects.add(subquery(rel, rel));
            }
        }
        return 'SELECT ' + String.join(selects, ', ') + ' FROM ' + baseObject + ' WHERE Id = :recordId LIMIT 1';
    }

    String subquery(String key, String relationshipName) {
        Map<String, String> fields = childFields.get(key);
        fields.put('id', 'Id');
        String sub = '(SELECT ' + String.join(fields.values(), ', ') + ' FROM ' + relationshipName;
        if (childOrder.containsKey(key)) {
            sub += ' ORDER BY ' + childOrder.get(key);
        }
        return sub + ' LIMIT ' + CHILD_ROW_LIMIT + ')';
    }

    List<SObject> loadParentList(String rel) {
        String childRel = rel.substringAfterLast('.');
        SObject parent = record;
        for (String part : rel.substringBeforeLast('.').split('\\.')) {
            if (parent == null) {
                return null;
            }
            parent = parent.getSObject(part);
        }
        if (parent == null || parent.Id == null) {
            return null;
        }
        Id parentId = parent.Id;
        String soql = 'SELECT Id, ' + subquery(rel, childRel) + ' FROM ' + String.valueOf(parentId.getSObjectType()) + ' WHERE Id = :parentId LIMIT 1';
        List<SObject> rows = Database.queryWithBinds(soql, new Map<String, Object>{ 'parentId' => parentId }, AccessLevel.USER_MODE);
        return rows.isEmpty() ? null : rows[0].getSObjects(childRel);
    }

    void collect() {
        addTokens(fileNamePattern, null);
        for (String key : new List<String>{ 'header', 'footer', 'watermark' }) {
            Map<String, Object> part = section(key);
            addTokens((String) part.get('text'), null);
            addRule(part.get('showIf'), null);
        }
        for (Object s : asList(body.get('signers'))) {
            Map<String, Object> signer = (Map<String, Object>) s;
            addTokens((String) signer.get('name'), null);
            addTokens((String) signer.get('email'), null);
        }
        for (Object b : blocks()) {
            Map<String, Object> blk = (Map<String, Object>) b;
            String type = (String) blk.get('type');
            addRule(blk.get('showIf'), null);
            addTokens((String) blk.get('elseText'), null);
            if (type == 'table') {
                String rel = safe((String) blk.get('source'));
                child(rel);
                for (Object c : asList(blk.get('columns'))) {
                    addField(child(rel), (String) ((Map<String, Object>) c).get('field'));
                }
                addRule(blk.get('rowFilter'), rel);
                String orderBy = (String) blk.get('orderBy');
                if (String.isNotBlank(orderBy)) {
                    String direction = 'DESC'.equalsIgnoreCase((String) blk.get('orderDirection')) ? ' DESC' : ' ASC';
                    childOrder.put(rel, safe(orderBy) + direction + ' NULLS LAST');
                }
            } else if (type == 'terms') {
                addTokens((String) blk.get('title'), null);
                for (Object i : asList(blk.get('items'))) {
                    Map<String, Object> item = (Map<String, Object>) i;
                    addTokens((String) item.get('text'), null);
                    addRule(item.get('showIf'), null);
                }
            } else {
                addTokens((String) blk.get('text'), null);
            }
        }
        for (Object c : asList(body.get('calculations'))) {
            Map<String, Object> calc = (Map<String, Object>) c;
            calcFormats.put((String) calc.get('name'), (String) calc.get('format'));
            if ('formula'.equalsIgnoreCase((String) calc.get('type'))) {
                Matcher m = EXPR_IDENT.matcher(calc.get('expression') == null ? '' : (String) calc.get('expression'));
                while (m.find()) {
                    if (!m.group().startsWith('calc:')) {
                        addField(parentFields, m.group());
                    }
                }
                continue;
            }
            String rel = safe((String) calc.get('source'));
            child(rel);
            if (calc.get('field') != null) {
                addField(child(rel), (String) calc.get('field'));
            }
            addRule(calc.get('filter'), rel);
        }
    }

    Map<String, String> child(String rel) {
        if (!childFields.containsKey(rel)) {
            childFields.put(rel, new Map<String, String>());
        }
        return childFields.get(rel);
    }

    void addField(Map<String, String> target, String path) {
        String clean = safe(path);
        target.put(clean.toLowerCase(), clean);
    }

    void addTokens(String text, String rel) {
        if (String.isBlank(text)) {
            return;
        }
        Matcher m = TOKEN.matcher(text);
        while (m.find()) {
            String path = m.group(1).trim();
            if (!path.startsWith('calc:')) {
                addField(rel == null ? parentFields : child(rel), path);
            }
        }
    }

    void addRule(Object ruleObj, String rel) {
        if (ruleObj == null) {
            return;
        }
        for (Object c : asList(((Map<String, Object>) ruleObj).get('conditions'))) {
            String field = (String) ((Map<String, Object>) c).get('field');
            if (field != null && !field.startsWith('calc:')) {
                addField(rel == null ? parentFields : child(rel), field);
            }
        }
    }

    void computeCalcs() {
        for (Object c : asList(body.get('calculations'))) {
            Map<String, Object> calc = (Map<String, Object>) c;
            String name = (String) calc.get('name');
            String type = calc.get('type') == null ? 'count' : ((String) calc.get('type')).toLowerCase();
            String field = (String) calc.get('field');
            if (type == 'formula') {
                calcs.put(name, new ExprParser((String) calc.get('expression'), this).evaluate());
                continue;
            }
            List<SObject> rows = rowsFor((String) calc.get('source'), calc.get('filter'));

            if (type == 'count') {
                calcs.put(name, rows.size());
                continue;
            }
            Decimal total = 0;
            Decimal lowest;
            Decimal highest;
            Integer counted = 0;
            for (SObject row : rows) {
                Object raw = resolve(row, field);
                if (raw == null) {
                    continue;
                }
                Decimal value = Decimal.valueOf(String.valueOf(raw));
                total += value;
                counted++;
                lowest = lowest == null || value < lowest ? value : lowest;
                highest = highest == null || value > highest ? value : highest;
            }
            if (type == 'sum') {
                calcs.put(name, total);
            } else if (type == 'avg') {
                calcs.put(name, counted == 0 ? 0 : (total / counted).setScale(2, RoundingMode.HALF_UP));
            } else if (type == 'min') {
                calcs.put(name, lowest == null ? 0 : lowest);
            } else if (type == 'max') {
                calcs.put(name, highest == null ? 0 : highest);
            } else {
                throw new DocBuilder.DocBuilderException('Calculation "' + name + '" has an unknown type: ' + type);
            }
        }
    }

    /** Child rows of a relationship, optionally narrowed by a row filter rule. */
    public List<SObject> rowsFor(String rel, Object filter) {
        List<SObject> all = lists.containsKey(rel) ? lists.get(rel) : new List<SObject>();
        if (filter == null) {
            return all;
        }
        List<SObject> kept = new List<SObject>();
        for (SObject row : all) {
            if (passes(filter, row, null)) {
                kept.add(row);
            }
        }
        return kept;
    }

    // ---------- Values and formatting ----------

    public Object resolve(SObject source, String path) {
        List<String> parts = path.split('\\.');
        SObject current = source;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (current == null) {
                return null;
            }
            current = current.getSObject(parts[i]);
        }
        return current == null ? null : current.get(parts[parts.size() - 1]);
    }

    Schema.DisplayType typeOf(SObject source, String path) {
        List<String> parts = path.split('\\.');
        SObject current = source;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (current == null) {
                return null;
            }
            current = current.getSObject(parts[i]);
        }
        if (current == null) {
            return null;
        }
        String key = String.valueOf(current.getSObjectType());
        if (!fieldMaps.containsKey(key)) {
            fieldMaps.put(key, current.getSObjectType().getDescribe().fields.getMap());
        }
        Schema.SObjectField field = fieldMaps.get(key).get(parts[parts.size() - 1]);
        return field == null ? null : field.getDescribe().getType();
    }

    public String formatValue(SObject source, String path, String format) {
        Object value = resolve(source, path);
        if (source === record) {
            usedValues.put(path, value);
        }
        if (value == null) {
            return '';
        }
        if (String.isNotBlank(format)) {
            return applyFormat(value, format);
        }
        Schema.DisplayType type = typeOf(source, path);
        if (type == Schema.DisplayType.CURRENCY) {
            return applyFormat(value, 'currency');
        }
        if (type == Schema.DisplayType.PERCENT) {
            return applyFormat(value, 'percent');
        }
        if (type == Schema.DisplayType.DATE) {
            return ((Date) value).format();
        }
        if (type == Schema.DisplayType.DATETIME) {
            return ((Datetime) value).format();
        }
        if (type == Schema.DisplayType.DOUBLE || type == Schema.DisplayType.INTEGER || type == Schema.DisplayType.LONG) {
            return applyFormat(value, 'number');
        }
        return String.valueOf(value);
    }

    public String formatCalc(String name, String format) {
        if (!calcs.containsKey(name)) {
            throw new DocBuilder.DocBuilderException('Calculated value "' + name + '" is not defined in the template.');
        }
        String chosen = String.isNotBlank(format) ? format : calcFormats.get(name);
        return applyFormat(calcs.get(name), String.isBlank(chosen) ? 'number' : chosen);
    }

    String applyFormat(Object value, String format) {
        String f = format.toLowerCase();
        if (f == 'upper') {
            return String.valueOf(value).toUpperCase();
        }
        if (f == 'lower') {
            return String.valueOf(value).toLowerCase();
        }
        if (f == 'date' && value instanceof Datetime) {
            return ((Datetime) value).date().format();
        }
        if (f == 'currency' || f == 'number' || f == 'percent') {
            Decimal d;
            try {
                d = Decimal.valueOf(String.valueOf(value));
            } catch (Exception e) {
                return String.valueOf(value);
            }
            if (f == 'currency') {
                d = d.setScale(2, RoundingMode.HALF_UP);
                String plain = d.abs().toPlainString();
                String whole = Long.valueOf(plain.substringBefore('.')).format();
                return (d < 0 ? '-' : '') + UserInfo.getDefaultCurrency() + ' ' + whole + '.' + plain.substringAfter('.');
            }
            if (f == 'percent') {
                return d.stripTrailingZeros().toPlainString() + '%';
            }
            return d.format();
        }
        return String.valueOf(value);
    }

    /** Replaces {{Field.Path}} and {{calc:Name}} tokens. With html=true the result is safe to place in markup. */
    public String mergeText(String text, SObject source, Boolean html) {
        if (String.isBlank(text)) {
            return '';
        }
        Matcher m = TOKEN.matcher(text);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            out += escape(text.substring(last, m.start()), html);
            String path = m.group(1).trim();
            String value = path.startsWith('calc:') ? formatCalc(path.substring(5), m.group(2)) : formatValue(source, path, m.group(2));
            out += escape(value, html);
            last = m.end();
        }
        out += escape(text.substring(last), html);
        return html ? out.replace('\r\n', '<br/>').replace('\n', '<br/>') : out;
    }

    public String mergeHtml(String text) {
        return mergeText(text, record, true);
    }

    /**
     * Merges tokens into rich text. The author's formatting is kept, unsafe markup is removed,
     * and every merged value is escaped so data can never inject markup.
     */
    public String mergeRich(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String clean = sanitize(html);
        Matcher m = TOKEN.matcher(clean);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            out += clean.substring(last, m.start());
            String path = m.group(1).trim();
            String value = path.startsWith('calc:') ? formatCalc(path.substring(5), m.group(2)) : formatValue(record, path, m.group(2));
            out += value == null ? '' : value.escapeHtml4();
            last = m.end();
        }
        return out + clean.substring(last);
    }

    public static String sanitize(String html) {
        String blocked = 'script|style|iframe|object|embed|link|meta|form|input|button';
        return html.replaceAll('(?is)<(' + blocked + ')\\b[^>]*>.*?</\\1\\s*>', '')
            .replaceAll('(?is)</?(' + blocked + ')\\b[^>]*>', '')
            .replaceAll('(?i)\\son[a-z]+\\s*=\\s*("[^"]*"|\'[^\']*\'|[^\\s>]+)', '')
            .replaceAll('(?i)javascript\\s*:', '')
            .replaceAll('(?i)<br\\s*>', '<br/>');
    }

    // ---------- Signers ----------

    /** Set when the document is being generated for e-signature. Null for ordinary documents. */
    public DocBuilderSignProvider signProvider;

    /**
     * The template's signers with their name and email worked out for this record.
     * Each is defined as { "role", "name", "email" }, where name and email may be typed text or field tokens.
     */
    /** Signers supplied by the sender, used in place of the template's own when present. */
    public List<DocBuilderSign.Signer> signerOverrides;

    public List<DocBuilderSign.Signer> resolveSigners() {
        if (signerOverrides != null && !signerOverrides.isEmpty()) {
            return signerOverrides;
        }
        List<DocBuilderSign.Signer> signers = new List<DocBuilderSign.Signer>();
        Integer position = 0;
        for (Object s : asList(body.get('signers'))) {
            Map<String, Object> definition = (Map<String, Object>) s;
            position++;
            DocBuilderSign.Signer signer = new DocBuilderSign.Signer();
            signer.role = definition.get('role') == null ? 'Signer ' + position : String.valueOf(definition.get('role'));
            signer.name = mergeText((String) definition.get('name'), record, false).trim();
            signer.email = mergeText((String) definition.get('email'), record, false).trim();
            signer.routingOrder = position;
            signers.add(signer);
        }
        return signers;
    }

    // ---------- Page setup ----------

    public Map<String, Object> pageSettings() {
        Object page = body.get('page');
        return page instanceof Map<String, Object> ? (Map<String, Object>) page : new Map<String, Object>();
    }

    /** One of the page sections: header, footer or watermark. Never null. */
    public Map<String, Object> section(String key) {
        Object part = pageSettings().get(key);
        return part instanceof Map<String, Object> ? (Map<String, Object>) part : new Map<String, Object>();
    }

    static String escape(String value, Boolean html) {
        return html && value != null ? value.escapeHtml4() : value;
    }

    // ---------- Rules ----------

    /**
     * Evaluates a rule: { "logic": "1 AND (2 OR 3)", "conditions": [ { "field", "op", "value" } ] }.
     * logic may be omitted or AND (all), OR (any), or an expression over the condition numbers.
     * Pass a logKey for block-level rules so the outcome is kept in the audit snapshot.
     */
    public Boolean passes(Object ruleObj, SObject source, String logKey) {
        if (ruleObj == null) {
            return true;
        }
        Map<String, Object> rule = (Map<String, Object>) ruleObj;
        List<Object> conditions = asList(rule.get('conditions'));
        if (conditions.isEmpty()) {
            return true;
        }

        List<Boolean> results = new List<Boolean>();
        List<Object> detail = new List<Object>();
        for (Object c : conditions) {
            Map<String, Object> condition = (Map<String, Object>) c;
            String field = (String) condition.get('field');
            String op = condition.get('op') == null ? 'eq' : (String) condition.get('op');
            String expected = condition.get('value') == null ? '' : String.valueOf(condition.get('value'));
            Boolean isCalc = field.startsWith('calc:');
            Object actual = isCalc ? (Object) calcs.get(field.substring(5)) : resolve(source, field);
            if (!isCalc && source === record) {
                usedValues.put(field, actual);
            }
            Boolean result = compare(actual, op, expected);
            results.add(result);
            detail.add(new Map<String, Object>{ 'field' => field, 'op' => op, 'value' => expected, 'actual' => actual, 'result' => result });
        }

        String logic = (String) rule.get('logic');
        Boolean outcome;
        if (String.isBlank(logic) || logic.trim().equalsIgnoreCase('AND')) {
            outcome = !results.contains(false);
        } else if (logic.trim().equalsIgnoreCase('OR')) {
            outcome = results.contains(true);
        } else {
            outcome = new LogicParser(logic, results).parse();
        }
        if (logKey != null) {
            logicLog.put(logKey, new Map<String, Object>{ 'logic' => String.isBlank(logic) ? 'AND' : logic, 'conditions' => detail, 'result' => outcome });
        }
        return outcome;
    }

    static Boolean compare(Object actual, String op, String expected) {
        String o = op.toLowerCase();
        Boolean isBlank = actual == null || String.valueOf(actual) == '';
        if (o == 'blank') {
            return isBlank;
        }
        if (o == 'notblank') {
            return !isBlank;
        }
        if (isBlank) {
            return o == 'ne';
        }
        String want = expected == null ? '' : expected.trim();
        if (actual instanceof Decimal || actual instanceof Integer || actual instanceof Long || actual instanceof Double) {
            Decimal a = Decimal.valueOf(String.valueOf(actual));
            Decimal b;
            try {
                b = Decimal.valueOf(want);
            } catch (Exception e) {
                return o == 'ne';
            }
            if (o == 'eq') {
                return a == b;
            }
            if (o == 'ne') {
                return a != b;
            }
            if (o == 'gt') {
                return a > b;
            }
            if (o == 'ge') {
                return a >= b;
            }
            if (o == 'lt') {
                return a < b;
            }
            if (o == 'le') {
                return a <= b;
            }
            return false;
        }
        String actualText = String.valueOf(actual).toLowerCase();
        String wantText = want.toLowerCase();
        if (o == 'eq') {
            return actualText.equals(wantText);
        }
        if (o == 'ne') {
            return !actualText.equals(wantText);
        }
        if (o == 'contains') {
            return actualText.contains(wantText);
        }
        Integer cmp = actualText.compareTo(wantText);
        if (o == 'gt') {
            return cmp > 0;
        }
        if (o == 'ge') {
            return cmp >= 0;
        }
        if (o == 'lt') {
            return cmp < 0;
        }
        if (o == 'le') {
            return cmp <= 0;
        }
        return false;
    }

    /** Parses expressions such as 1 AND (2 OR NOT 3) over a list of condition results. */
    public class LogicParser {
        List<String> tokens = new List<String>();
        List<Boolean> results;
        Integer pos = 0;
        Boolean ok = true;
        String source;

        public LogicParser(String logic, List<Boolean> results) {
            this.results = results;
            this.source = logic;
            String upper = logic.toUpperCase();
            Matcher m = Pattern.compile('\\d+|AND|OR|NOT|\\(|\\)').matcher(upper);
            while (m.find()) {
                tokens.add(m.group());
            }
            if (String.isNotBlank(upper.replaceAll('\\d+|AND|OR|NOT|\\(|\\)|\\s+', ''))) {
                ok = false;
            }
        }

        public Boolean parse() {
            Boolean value = tokens.isEmpty() ? false : orExpr();
            if (tokens.isEmpty() || pos < tokens.size()) {
                ok = false;
            }
            if (!ok) {
                throw new DocBuilder.DocBuilderException('Rule logic cannot be read: ' + source);
            }
            return value;
        }

        Boolean factor() {
            if (pos >= tokens.size()) {
                ok = false;
                return false;
            }
            String token = tokens[pos++];
            if (token == 'NOT') {
                return !factor();
            }
            if (token == '(') {
                Boolean grouped = orExpr();
                if (pos >= tokens.size() || tokens[pos++] != ')') {
                    ok = false;
                }
                return grouped;
            }
            if (!token.isNumeric()) {
                ok = false;
                return false;
            }
            Integer n = Integer.valueOf(token);
            if (n < 1 || n > results.size()) {
                ok = false;
                return false;
            }
            return results[n - 1];
        }

        Boolean andExpr() {
            Boolean value = factor();
            while (pos < tokens.size() && tokens[pos] == 'AND') {
                pos++;
                Boolean nextValue = factor();
                value = value && nextValue;
            }
            return value;
        }

        Boolean orExpr() {
            Boolean value = andExpr();
            while (pos < tokens.size() && tokens[pos] == 'OR') {
                pos++;
                Boolean nextValue = andExpr();
                value = value || nextValue;
            }
            return value;
        }
    }

    /**
     * Evaluates arithmetic for formula calculations, e.g. Amount * (1 - Discount__c / 100) or calc:Subtotal * 0.9.
     * Operands are numbers, fields on the source record (or its parents) and earlier calculations.
     */
    public class ExprParser {
        List<String> tokens = new List<String>();
        Integer pos = 0;
        String source;
        DocBuilderContext ctx;

        public ExprParser(String expression, DocBuilderContext ctx) {
            this.source = expression == null ? '' : expression;
            this.ctx = ctx;
            String tokenPattern = '\\d+(\\.\\d+)?|calc:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_.]*|[-+*/()]';
            Matcher m = Pattern.compile(tokenPattern).matcher(source);
            while (m.find()) {
                tokens.add(m.group());
            }
            if (tokens.isEmpty() || String.isNotBlank(source.replaceAll(tokenPattern + '|\\s+', ''))) {
                fail();
            }
        }

        void fail() {
            throw new DocBuilder.DocBuilderException('Formula cannot be read: ' + source);
        }

        public Decimal evaluate() {
            Decimal value = sum();
            if (pos < tokens.size()) {
                fail();
            }
            return value;
        }

        Decimal sum() {
            Decimal value = product();
            while (pos < tokens.size() && (tokens[pos] == '+' || tokens[pos] == '-')) {
                String op = tokens[pos++];
                Decimal nextValue = product();
                value = op == '+' ? value + nextValue : value - nextValue;
            }
            return value;
        }

        Decimal product() {
            Decimal value = unary();
            while (pos < tokens.size() && (tokens[pos] == '*' || tokens[pos] == '/')) {
                String op = tokens[pos++];
                Decimal nextValue = unary();
                if (op == '*') {
                    value = value * nextValue;
                } else {
                    value = nextValue == 0 ? 0 : value.divide(nextValue, 6, RoundingMode.HALF_UP);
                }
            }
            return value;
        }

        Decimal unary() {
            if (pos < tokens.size() && tokens[pos] == '-') {
                pos++;
                return -unary();
            }
            return operand();
        }

        Decimal operand() {
            if (pos >= tokens.size()) {
                fail();
            }
            String token = tokens[pos++];
            if (token == '(') {
                Decimal grouped = sum();
                if (pos >= tokens.size() || tokens[pos++] != ')') {
                    fail();
                }
                return grouped;
            }
            if (token.left(1).isNumeric()) {
                return Decimal.valueOf(token);
            }
            if (token.startsWith('calc:')) {
                String name = token.substring(5);
                if (!ctx.calcs.containsKey(name)) {
                    throw new DocBuilder.DocBuilderException('Formula uses "' + name + '" before it is calculated. Move it above this formula.');
                }
                return ctx.calcs.get(name);
            }
            if (token == ')' || token == '+' || token == '*' || token == '/') {
                fail();
            }
            Object raw = ctx.resolve(ctx.record, token);
            ctx.usedValues.put(token, raw);
            if (raw == null) {
                return 0;
            }
            try {
                return Decimal.valueOf(String.valueOf(raw));
            } catch (Exception e) {
                throw new DocBuilder.DocBuilderException('Formula field "' + token + '" is not a number.');
            }
        }
    }

    // ---------- Audit snapshot ----------

    public String snapshotJson(String templateName, Decimal versionNumber) {
        Map<String, Object> listData = new Map<String, Object>();
        for (String rel : lists.keySet()) {
            List<Object> rows = new List<Object>();
            for (SObject row : lists.get(rel)) {
                Map<String, Object> values = new Map<String, Object>();
                for (String path : childFields.get(rel).values()) {
                    values.put(path, resolve(row, path));
                }
                rows.add(values);
            }
            listData.put(rel, rows);
        }

        Map<String, Object> snapshot = new Map<String, Object>{
            'template' => templateName,
            'templateVersion' => versionNumber,
            'generatedAt' => System.now(),
            'generatedBy' => UserInfo.getUserId(),
            'object' => baseObject,
            'recordId' => recordId,
            'values' => usedValues,
            'lists' => listData,
            'calculations' => calcs,
            'logic' => logicLog
        };
        String serialized = JSON.serializePretty(snapshot);
        if (serialized.length() > SNAPSHOT_LIMIT) {
            snapshot.put('lists', new Map<String, Object>());
            snapshot.put('listsOmitted', 'Row data was too large to store with this record.');
            serialized = JSON.serializePretty(snapshot);
        }
        return serialized.left(SNAPSHOT_LIMIT);
    }
}
