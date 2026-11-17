/**
 * "Send Document for Signature" action for Flow. Use it in a record-triggered flow to send automatically,
 * or inside a screen flow that replaces the built-in signing screen.
 */
global with sharing class DocBuilderSignFlowAction {
    global class Input {
        @InvocableVariable(label='Template Name' description='Name of an active document template' required=true)
        global String templateName;
        @InvocableVariable(label='Record ID' description='Record to generate the document from' required=true)
        global Id recordId;
        @InvocableVariable(label='Signature Provider' description='Developer name of a Signature Provider row, for example DocuSign' required=true)
        global String providerName;
        @InvocableVariable(label='Language')
        global String language;
        @InvocableVariable(label='Subject')
        global String subject;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Signer Emails' description='Optional. Comma separated, in signing order. Replaces the emails defined on the template.')
        global String signerEmails;
    }

    global class Output {
        @InvocableVariable(label='Succeeded')
        global Boolean success;
        @InvocableVariable(label='Signature Request ID')
        global String signatureRequestId;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Send Document for Signature' description='Generates a document from a DocBuilder template and sends it for e-signature' category='DocBuilder')
    global static List<Output> send(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        for (Input input : inputs) {
            Output output = new Output();
            output.success = false;
            try {
                List<DocTemplate__c> templates = [SELECT Id FROM DocTemplate__c WHERE Name = :input.templateName AND Status__c = 'Active' ORDER BY CreatedDate DESC LIMIT 1];
                if (templates.isEmpty()) {
                    throw new DocBuilder.DocBuilderException('No active template named "' + input.templateName + '".');
                }
                DocBuilderSign.SendRequest request = new DocBuilderSign.SendRequest();
                request.templateId = templates[0].Id;
                request.recordId = input.recordId;
                request.providerName = input.providerName;
                request.language = input.language;
                request.subject = input.subject;
                request.message = input.message;
                if (String.isNotBlank(input.signerEmails)) {
                    request.signers = new List<DocBuilderSign.Signer>();
                    for (String email : input.signerEmails.split('[,;]')) {
                        if (String.isNotBlank(email)) {
                            DocBuilderSign.Signer signer = new DocBuilderSign.Signer();
                            signer.email = email.trim();
                            signer.name = email.trim();
                            request.signers.add(signer);
                        }
                    }
                }
                output.signatureRequestId = DocBuilderSign.send(request);
                output.success = true;
            } catch (Exception e) {
                output.errorMessage = e.getMessage();
            }
            outputs.add(output);
        }
        return outputs;
    }
}
