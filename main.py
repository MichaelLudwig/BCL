import streamlit as st
import openai
from openai import OpenAI
import os
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv



# Lade Umgebungsvariablen aus .env
load_dotenv()

st.set_page_config(
    page_title="BCL AI Chat",
    page_icon="🤖",
    layout="wide"
)

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

# Chat Interface -------------------------------------------------------------

# initialize chat session in streamlit if not already present
if "chat_history" not in st.session_state:
    st.session_state.chat_history = []

# streamlit page title
st.title("🤖 BCL AI Chat zu Bauordnungen")

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
        temperature=0.1,
        max_tokens=15000,
        messages=[
            {"role": "system", "content": """Du bist ein hilfreicher Assistent für Bauordnungen. 
            Suche in dem Index 'bcl-data2' nach relevanten Informationen für die Antwort.
            
            Wichtige Anweisungen für deine Antworten:
            - Referenziere alle Quellen nach jeder Aussage im Format (refX)
            - Halte dich ausschließlich an die Informationen aus den gefundenen Dokumenten und gib diese möglichst vollständig wieder.
            - Mache keine Interpretationen oder Ableitungen
            - Verwende nur Fakten, die direkt in den Dokumenten stehen
            - Gib "Keine Information verfügbar" aus, wenn du keine eindeutige Antwort findest
            - Vermeide kreative oder spekulative Ergänzungen
            
            Versuche dich sehr genau an den Inhalten der dir vorliegenden Informationen zu halten. Referenziere alle Quellen nach jeder Aussage im Format (refX).
            Liste am Ende deiner Ausführungen die verwendeten Quellen mit dem Vollständigen Titel des Quelldokumentes welchen du aus dem Dokument extrahieren kannst,
            Paragraphnummer , Abschnittsnummer, Satznummer, Dokumenttitel {title}, Bundesland {Bundesland} und Baukategorie {Baukategorie} auf. 
             Sollte das Dokument keine Paragraphen enthalten, so gib die Information zu Kapitel und Unterkapitel an.
             Die Information zu Bundesland und Baukategorie ist in dem Feld filepath enthalten. Hier ein Beispiel: https://storedlzdivyxevanm.blob.core.windows.net/documents/Regelwerke/Sachsen/Garagen/S%C3%A4chsGarVO_1995-01_inkl.%20%C3%84nd_2004.pdf
             In dem Ordner Regelwerke liegen jeweils die Unterordner für die Bundesländer. Darunter liegen die Unterordner für die Baukategorien.
             
            Der Gesetzestext ist in chunks geteilt, um die Suche zu beschleunigen und das LLM zu entlasten.
            Um die nötigen Informationen wie Paragraphnummer und Paragraphname zu finden, musst meist du die vorrangegangenen Chunks des Chunks durchsuchen, aus dem du die Information extrahiert hast.
            Paragraphennummern und Titel stehen immer vor der Aussage im Chunk.
            
            Verwende und verweise immer auf die aktuellste Version der jeweiligen Bauordnung. Diese geht aus dem Titel der Quelle hervor.
            Die Bauorndung '04_SächsFeuVO_2007-10-15_inkl Änd 2020-03.pdf' wurde z.b. im März 2020 geändert {date}.

            Quellen:
            - {title} (Bundesland: {Bundesland}, Baukategorie: {Baukategorie}, Datum der letzten Änderung: {date})
            
            Beispiel:
            Quellen:
            - (ref1):   $ 5 Abschnitt 4 Satze 3 aus der Verordnung des Sächsischen Staatsministeriums für Regionalentwicklung zur Änderung der Ressortbezeichnung 
                        SächsBO_2016-05_inkl Änd 2022-06_mit Begründung-Auszügen.pdf (Bundesland: Sachsen, Baukategorie: Bauordnung, Datum der letzten Änderung: 2022-06)
            - (ref2):   2.6 Sicherheitsbeleuchtung und 2.7 Blitzschutzanlagen aus der Verordnung des Sächsischen Staatsministeriums für Regionalentwicklung zur Änderung der Ressortbezeichnung 
                        SächsBO_2016-05_inkl Änd 2022-06_mit Begründung-Auszügen.pdf (Bundesland: Sachsen, Baukategorie: Bauordnung, Datum der letzten Änderung: 2022-06)
            """},
            *st.session_state.chat_history
        ],
        extra_body={
            "data_sources": [
                {
                    "type": "azure_search",
                    "parameters": {
                        "endpoint": "https://searchbclapp.search.windows.net",
                        "index_name": "bcl-data2",
                        "authentication": {
                            "type": "system_assigned_managed_identity"
                        },
                        "top_k": 8,
                        "fields_mapping": {
                            "content_field": "chunk",
                            "vector_fields": ["text_vector"],
                            "title_field": "title",
                            "metadata_fields": ["Bundesland", "Baukategorie"]
                        },
                        "hybrid_search": {
                            "fields": ["text_vector"],
                            "k": 8
                        }
                    }
                }
            ]
        }
    )

    assistant_response = response.choices[0].message.content
    st.session_state.chat_history.append({"role": "assistant", "content": assistant_response})

    # display GPT-4o's response
    with st.chat_message("assistant"):
        st.markdown(assistant_response)
        st.text("Prompt Token: " + str(response.usage.prompt_tokens) + " Response Token: " + str(response.usage.completion_tokens))
        
        # Zeige Suchergebnisse und Scores
        st.json(response.choices[0].message.context)




        