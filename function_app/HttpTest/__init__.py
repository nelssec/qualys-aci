import logging
import azure.functions as func


def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('HTTP trigger function processed a request.')

    return func.HttpResponse(
        "Function runtime is working!",
        status_code=200
    )
