/**
 * SAMPLE Custom content (Apex class): the line items of a quote or opportunity grouped by product family,
 * with a subtotal per family and a grand total. A plain template table cannot group rows like this.
 *
 * Use it: add a Custom block, choose "An Apex class", enter DocBuilderSampleProductSummary.
 * Settings (optional): {"title": "Your investment"} or just the title as plain text.
 */
global with sharing class DocBuilderSampleProductSummary implements DocBuilderContentProvider {
    global String render(DocBuilderContentRequest request) {
        if (request.recordId == null) {
            return '<p>Products by family appear here for a real record.</p>';
        }
        String title = titleFrom(request.settings);
        String objectName = String.valueOf(request.recordId.getSObjectType());
        List<Line> lines = new List<Line>();
        if (objectName == 'Quote') {
            for (QuoteLineItem item : [
                SELECT Product2.Name, Product2.Family, Quantity, TotalPrice
                FROM QuoteLineItem
                WHERE QuoteId = :request.recordId
                WITH USER_MODE
                ORDER BY Product2.Family NULLS LAST, Product2.Name
            ]) {
                lines.add(new Line(item.Product2.Family, item.Product2.Name, item.Quantity, item.TotalPrice));
            }
        } else if (objectName == 'Opportunity') {
            for (OpportunityLineItem item : [
                SELECT Product2.Name, Product2.Family, Quantity, TotalPrice
                FROM OpportunityLineItem
                WHERE OpportunityId = :request.recordId
                WITH USER_MODE
                ORDER BY Product2.Family NULLS LAST, Product2.Name
            ]) {
                lines.add(new Line(item.Product2.Family, item.Product2.Name, item.Quantity, item.TotalPrice));
            }
        } else {
            return '<p>The product summary sample works on quotes and opportunities.</p>';
        }
        if (lines.isEmpty()) {
            return '<p>There are no products on this record yet.</p>';
        }

        // Families in alphabetical order, with products that have no family ("Other") last.
        Map<String, List<Line>> byFamily = new Map<String, List<Line>>();
        for (Line line : lines) {
            if (!byFamily.containsKey(line.family)) {
                byFamily.put(line.family, new List<Line>());
            }
            byFamily.get(line.family).add(line);
        }
        List<String> families = new List<String>(byFamily.keySet());
        families.sort();
        if (byFamily.containsKey(OTHER)) {
            families.remove(families.indexOf(OTHER));
            families.add(OTHER);
        }

        String html = '<h3>' + title.escapeHtml4() + '</h3><table class="t"><thead><tr><th>Product</th><th class="r">Quantity</th><th class="r">Total</th></tr></thead><tbody>';
        Decimal grandTotal = 0;
        for (String family : families) {
            Decimal familyTotal = 0;
            html += '<tr><td colspan="3"><b>' + family.escapeHtml4() + '</b></td></tr>';
            for (Line line : byFamily.get(family)) {
                familyTotal += line.total;
                html += '<tr><td>' + line.product.escapeHtml4() + '</td><td class="r">' + line.quantity.format() + '</td><td class="r">' + money(line.total) + '</td></tr>';
            }
            grandTotal += familyTotal;
            html += '<tr class="tot"><td colspan="2" class="r">' + family.escapeHtml4() + ' subtotal</td><td class="r">' + money(familyTotal) + '</td></tr>';
        }
        return html + '<tr class="tot"><td colspan="2" class="r">Total</td><td class="r">' + money(grandTotal) + '</td></tr></tbody></table>';
    }

    static final String OTHER = 'Other';

    static String titleFrom(String settings) {
        if (String.isBlank(settings)) {
            return 'Products by family';
        }
        try {
            Object title = ((Map<String, Object>) JSON.deserializeUntyped(settings)).get('title');
            return title == null ? 'Products by family' : String.valueOf(title);
        } catch (Exception e) {
            // Settings that are not JSON are used as the title as they are.
            return settings.trim();
        }
    }

    /** Always two decimals, with thousands separators: USD 1,250.00 */
    static String money(Decimal amount) {
        Decimal rounded = amount.setScale(2, RoundingMode.HALF_UP);
        String plain = rounded.abs().toPlainString();
        String whole = Long.valueOf(plain.substringBefore('.')).format();
        return (rounded < 0 ? '-' : '') + UserInfo.getDefaultCurrency() + ' ' + whole + '.' + plain.substringAfter('.');
    }

    class Line {
        String family;
        String product;
        Decimal quantity;
        Decimal total;
        Line(String family, String product, Decimal quantity, Decimal total) {
            this.family = String.isBlank(family) ? OTHER : family;
            this.product = product == null ? '' : product;
            this.quantity = quantity == null ? 0 : quantity;
            this.total = total == null ? 0 : total;
        }
    }
}
