/**
 * "Generate Document" action for Flow. Each input produces one document.
 */
global with sharing class DocBuilderFlowAction {
    global class Input {
        @InvocableVariable(label='Template Name' description='Name of an active document template' required=true)
        global String templateName;
        @InvocableVariable(label='Record ID' description='Record to generate the document from' required=true)
        global Id recordId;
        @InvocableVariable(label='Save to Files on the Record' description='Defaults to true')
        global Boolean saveToRecord;
        @InvocableVariable(label='Email To' description='Optional. One or more addresses separated by commas')
        global String emailTo;
        @InvocableVariable(label='Email Subject')
        global String emailSubject;
        @InvocableVariable(label='Email Body')
        global String emailBody;
    }

    global class Output {
        @InvocableVariable(label='Succeeded')
        global Boolean success;
        @InvocableVariable(label='Document Record ID')
        global String documentId;
        @InvocableVariable(label='File ID (Content Version)')
        global String contentVersionId;
        @InvocableVariable(label='File Name')
        global String fileName;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Generate Document' description='Generates a PDF from a DocBuilder template for a record' category='DocBuilder')
    global static List<Output> generate(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        for (Input input : inputs) {
            DocBuilder.Request req = new DocBuilder.Request();
            req.templateName = input.templateName;
            req.recordId = input.recordId;
            req.saveToRecord = input.saveToRecord != false;
            req.emailSubject = input.emailSubject;
            req.emailBody = input.emailBody;
            req.channel = 'Flow';
            if (String.isNotBlank(input.emailTo)) {
                req.emailTo = new List<String>();
                for (String address : input.emailTo.split('[,;]')) {
                    if (String.isNotBlank(address)) {
                        req.emailTo.add(address.trim());
                    }
                }
            }

            DocBuilder.Result res = DocBuilder.generate(req);
            Output output = new Output();
            output.success = res.success;
            output.documentId = res.documentId;
            output.contentVersionId = res.contentVersionId;
            output.fileName = res.fileName;
            output.errorMessage = res.errorMessage;
            outputs.add(output);
        }
        return outputs;
    }
}
