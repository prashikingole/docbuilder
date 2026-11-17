import { LightningElement, api } from 'lwc';

const OPS = [
    { label: 'equals', value: 'eq' },
    { label: 'does not equal', value: 'ne' },
    { label: 'is greater than', value: 'gt' },
    { label: 'is at least', value: 'ge' },
    { label: 'is less than', value: 'lt' },
    { label: 'is at most', value: 'le' },
    { label: 'contains', value: 'contains' },
    { label: 'is blank', value: 'blank' },
    { label: 'is not blank', value: 'notBlank' }
];

/**
 * Edits one rule: { logic, conditions: [{ field, op, value }] }.
 * Fires "rulechange" with detail.rule (null when there are no conditions).
 */
export default class DocBuilderRule extends LightningElement {
    ops = OPS;
    conditions = [];
    logic = '';

    @api
    get rule() {
        return this.build();
    }
    set rule(value) {
        const conditions = value && Array.isArray(value.conditions) ? value.conditions : [];
        this.conditions = conditions.map((c) => ({ field: c.field || '', op: c.op || 'eq', value: c.value == null ? '' : String(c.value) }));
        this.logic = (value && value.logic) || '';
    }

    get rows() {
        return this.conditions.map((c, index) => ({ ...c, index, num: index + 1 }));
    }

    get hasRows() {
        return this.conditions.length > 0;
    }

    build() {
        if (!this.conditions.length) {
            return null;
        }
        const rule = { conditions: this.conditions.map((c) => ({ ...c })) };
        if (this.logic && this.logic.trim()) {
            rule.logic = this.logic.trim();
        }
        return rule;
    }

    notify() {
        this.dispatchEvent(new CustomEvent('rulechange', { detail: { rule: this.build() } }));
    }

    handleChange(event) {
        const index = Number(event.target.dataset.index);
        const prop = event.target.dataset.prop;
        this.conditions = this.conditions.map((c, i) => (i === index ? { ...c, [prop]: event.detail.value } : c));
        this.notify();
    }

    handleLogic(event) {
        this.logic = event.detail.value;
        this.notify();
    }

    handleAdd() {
        this.conditions = [...this.conditions, { field: '', op: 'eq', value: '' }];
        this.notify();
    }

    handleRemove(event) {
        const index = Number(event.target.dataset.index);
        this.conditions = this.conditions.filter((c, i) => i !== index);
        if (!this.conditions.length) {
            this.logic = '';
        }
        this.notify();
    }
}
