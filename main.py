import streamlit as st
import openai
from openai import OpenAI
import os
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery

st.set_page_config(layout="wide")

# Lade Umgebungsvariablen aus .env
load_dotenv()

# OpenAI API Aufruf -------------------------------------------------------------

if os.getenv('WEBSITE_INSTANCE_ID'):
    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
    )
    client = openai.AzureOpenAI(
        azure_ad_token_provider=token_provider,
        api_version="2024-04-01-preview",
        azure_endpoint="https://ai-service-BCL-app.openai.azure.com/"        
    )
else:
    st.write("Locale Testumgebung")
    client = openai.AzureOpenAI(
        api_key=os.getenv('AZURE_OPENAI_API_KEY'),
        api_version="2024-04-01-preview",
        azure_endpoint="https://ai-service-BCL-app.openai.azure.com/"
    )
openAI_model = "gpt-4o-mini"

# Search Client Setup
search_client = SearchClient(
    endpoint=f"https://searchbclapp.search.windows.net",
    index_name="bcl-data",
    credential=DefaultAzureCredential()
)

# Chat Interface -------------------------------------------------------------

# initialize chat session in streamlit if not already present
if "chat_history" not in st.session_state:
    st.session_state.chat_history = []

# streamlit page title
st.title("🤖 Azure OpenAI GPT-4o-mini ChatBot")

# display chat history
for message in st.session_state.chat_history:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])


# input field for user's message
user_prompt = st.chat_input("Frag GPT-4o-mini...")

if user_prompt:
    # add user's message to chat and display it
    st.chat_message("user").markdown(user_prompt)
    st.session_state.chat_history.append({"role": "user", "content": user_prompt})

    # send user's message to GPT-4o and get a response
    response = client.chat.completions.create(
        model=openAI_model,
        messages=[
            {"role": "system", "content": "Du bist ein hilfreicher Assistent. Suche in dem Index 'bcl-data' nach relevanten Informationen für die Antwort."},
            *st.session_state.chat_history
        ],
        extra_body={
            "dataSources": [{
                "type": "AzureCognitiveSearch",
                "parameters": {
                    "endpoint": "https://searchbclapp.search.windows.net",
                    "indexName": "bcl-data",
                    "queryType": "vector",
                    "fieldsMapping": {
                        "contentField": "content",
                        "vectorFields": ["contentVector"]
                    }
                }
            }]
        }
    )

    assistant_response = response.choices[0].message.content
    st.session_state.chat_history.append({"role": "assistant", "content": assistant_response})

    # display GPT-4o's response
    with st.chat_message("assistant"):
        st.markdown(assistant_response)

        