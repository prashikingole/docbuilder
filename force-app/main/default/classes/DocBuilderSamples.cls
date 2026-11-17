/**
 * Installs a ready-to-use sample template so a new org has something to generate straight away.
 * Run once from Anonymous Apex: DocBuilderSamples.installOpportunityQuote();
 */
public with sharing class DocBuilderSamples {
    public static final String QUOTE_NAME = 'Sample Opportunity Quote';

    public static Id installOpportunityQuote() {
        List<DocTemplate__c> existing = [SELECT Id FROM DocTemplate__c WHERE Name = :QUOTE_NAME LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        return createTemplate(QUOTE_NAME, 'Opportunity', 'Quote - {{Account.Name}} - {{Name}}', JSON.serializePretty(quoteBody()));
    }

    /** Creates an active template with one active version. */
    public static Id createTemplate(String name, String baseObject, String fileNamePattern, String bodyJson) {
        DocTemplate__c template = new DocTemplate__c(Name = name, Base_Object__c = baseObject, File_Name_Pattern__c = fileNamePattern, Status__c = 'Draft');
        insert template;
        DocTemplateVersion__c version = new DocTemplateVersion__c(
            Template__c = template.Id,
            Version_Number__c = 1,
            Status__c = 'Active',
            Activated_On__c = System.now(),
            Body_JSON__c = bodyJson
        );
        insert version;
        template.Active_Version__c = version.Id;
        template.Status__c = 'Active';
        update template;
        return template.Id;
    }

    static Map<String, Object> cond(String field, String op, Object value) {
        return new Map<String, Object>{ 'field' => field, 'op' => op, 'value' => value };
    }

    static Map<String, Object> quoteBody() {
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{ 'id' => 'title', 'type' => 'heading', 'text' => 'Quote', 'align' => 'right' },
            new Map<String, Object>{ 'id' => 'validity', 'type' => 'text', 'align' => 'right', 'text' => 'Expected close: {{CloseDate}}' },
            new Map<String, Object>{ 'id' => 'customer', 'type' => 'text', 'text' => 'Prepared for\n{{Account.Name}}' },
            new Map<String, Object>{
                'id' => 'intro',
                'type' => 'text',
                'text' => 'Thank you for considering us. Below is our proposal for {{Name}}. Please reach out to {{Owner.Name}} with any questions.'
            },
            new Map<String, Object>{
                'id' => 'products',
                'type' => 'table',
                'source' => 'OpportunityLineItems',
                'orderBy' => 'SortOrder',
                'hideWhenEmpty' => true,
                'columns' => new List<Object>{
                    new Map<String, Object>{ 'header' => 'Product', 'field' => 'Product2.Name' },
                    new Map<String, Object>{ 'header' => 'Quantity', 'field' => 'Quantity', 'align' => 'right' },
                    new Map<String, Object>{ 'header' => 'Unit price', 'field' => 'UnitPrice', 'align' => 'right' },
                    new Map<String, Object>{ 'header' => 'Line total', 'field' => 'TotalPrice', 'align' => 'right' }
                },
                'totals' => new List<Object>{ new Map<String, Object>{ 'label' => 'Total', 'calc' => 'Subtotal' } }
            },
            new Map<String, Object>{
                'id' => 'summary',
                'type' => 'text',
                'align' => 'right',
                'text' => 'Number of products: {{calc:LineCount}}\nOpportunity amount: {{Amount}}'
            },
            new Map<String, Object>{
                'id' => 'largeDeal',
                'type' => 'text',
                'text' => 'As a valued customer you qualify for a dedicated onboarding manager.',
                'elseText' => 'Standard onboarding applies to this quote.',
                'showIf' => new Map<String, Object>{
                    'logic' => '1 AND (2 OR 3)',
                    'conditions' => new List<Object>{ cond('Amount', 'gt', 10000), cond('calc:LineCount', 'ge', 2), cond('Account.Industry', 'eq', 'Logistics') }
                }
            },
            new Map<String, Object>{
                'id' => 'terms',
                'type' => 'terms',
                'title' => 'Terms',
                'items' => new List<Object>{
                    new Map<String, Object>{ 'id' => 'pay', 'text' => 'Payment is due within 30 days of the invoice date.' },
                    new Map<String, Object>{ 'id' => 'tax', 'text' => 'Prices are exclusive of applicable taxes.' },
                    new Map<String, Object>{
                        'id' => 'big',
                        'text' => 'Orders above 10,000 include priority support for the first year.',
                        'showIf' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Amount', 'gt', 10000) } }
                    },
                    new Map<String, Object>{
                        'id' => 'won',
                        'text' => 'This document confirms an accepted order.',
                        'showIf' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('StageName', 'eq', 'Closed Won') } }
                    }
                }
            }
        };
        List<Object> calculations = new List<Object>{
            new Map<String, Object>{ 'name' => 'Subtotal', 'type' => 'sum', 'source' => 'OpportunityLineItems', 'field' => 'TotalPrice', 'format' => 'currency' },
            new Map<String, Object>{ 'name' => 'LineCount', 'type' => 'count', 'source' => 'OpportunityLineItems' }
        };
        return new Map<String, Object>{ 'blocks' => blocks, 'calculations' => calculations };
    }
}
