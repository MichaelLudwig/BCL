import os
import json
import openai
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from pydantic import BaseModel, Field
from typing import List

# Pydantic Model für die Dokumentenstruktur
class Dokumenteninfo(BaseModel):
    bauvorhaben: str = Field(description="Name und Beschreibung des Bauvorhabens")
    bauherr: str = Field(description="Name und Anschrift des Bauherrn")
    entwurfsverfasser: str = Field(description="Name und Anschrift des Entwurfsverfassers")
    erstellt_am: str = Field(description="Erstellungsdatum des Dokuments")
    bundesland: str = Field(description="Bundesland in dem das Bauvorhaben realisiert wird")
    zielstellung: str = Field(description="Kurze Zusammenfassung der Zielstellung des Projekts", max_length=500)
    bauordnungsrechtliche_grundlagen: List[str] = Field(
        description="Liste der relevanten bauordnungsrechtlichen Grundlagen und Vorschriften"
    )

class OpenAIAPI:
    def __init__(self):
        if os.getenv('WEBSITE_INSTANCE_ID'):
            token_provider = get_bearer_token_provider(
                DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
            )
            self.client = openai.AzureOpenAI(
                azure_ad_token_provider=token_provider,
                api_version="2024-04-01-preview",
                azure_endpoint="https://ai-service-BCL-app.openai.azure.com/"        
            )
        else:
            self.client = openai.AzureOpenAI(
                api_key=os.getenv('AZURE_OPENAI_SW_API_KEY'),
                api_version="2024-04-01-preview",
                azure_endpoint="https://mlu-azure-openai-service-sw.openai.azure.com/"
            )
        
        self.model = "gpt-4o-mini"

    def extract_document_info(self, content: str) -> Dokumenteninfo:
        """Extrahiert Dokumentinformationen aus dem Inhalt mittels Azure OpenAI"""
        system_prompt = """
        Du bist ein Experte für die Analyse von Baudokumenten. Deine Aufgabe ist es, die angeforderten Informationen aus dem Dokument zu extrahieren
        und in einem spezifischen JSON-Format zurückzugeben. Das Format MUSS exakt folgendem Schema entsprechen:

        {
            "bauvorhaben": "Name und Beschreibung des Bauvorhabens",
            "bauherr": "Name und Anschrift des Bauherrn",
            "entwurfsverfasser": "Name und Anschrift des Entwurfsverfassers",
            "erstellt_am": "Datum der Dokumentenerstellung",
            "bundesland": "Bundesland des Bauvorhabens",
            "zielstellung": "Kurze Zusammenfassung der Zielstellung",
            "bauordnungsrechtliche_grundlagen": ["Grundlage 1", "Grundlage 2", "..."]
        }

        Wichtige Regeln:
        1. Alle Felder MÜSSEN vorhanden sein
        2. Wenn eine Information nicht gefunden wird, verwende "Nicht angegeben"
        3. bauordnungsrechtliche_grundlagen MUSS ein Array sein, auch wenn leer
        4. Halte die Zielstellung kurz und prägnant
        5. Das Bundesland ist wichtig für die geltenden Vorschriften, suche sorgfältig danach
        """
        
        user_prompt = f"""
        Analysiere den folgenden Dokumenteninhalt und extrahiere die relevanten Informationen.
        Achte besonders auf das Deckblatt und die ersten Kapitel.
        Gib die Informationen exakt im vorgegebenen JSON-Format zurück.

        Dokumenteninhalt:
        {content}
        """
        
        try:
            response = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                temperature=0.3,
                response_format={"type": "json_object"}
            )
            
            result = json.loads(response.choices[0].message.content)
            
            # Stelle sicher, dass alle erforderlichen Felder vorhanden sind
            default_info = {
                "bauvorhaben": "Nicht angegeben",
                "bauherr": "Nicht angegeben",
                "entwurfsverfasser": "Nicht angegeben",
                "erstellt_am": "Nicht angegeben",
                "bundesland": "Nicht angegeben",
                "zielstellung": "Nicht angegeben",
                "bauordnungsrechtliche_grundlagen": []
            }
            
            # Kombiniere die Default-Werte mit den extrahierten Informationen
            result = {**default_info, **result}
            
            return Dokumenteninfo(**result)
            
        except json.JSONDecodeError as e:
            raise Exception(f"Ungültiges JSON-Format in der OpenAI-Antwort: {response.choices[0].message.content}")
            
        except Exception as e:
            raise Exception(f"Fehler bei der Verarbeitung der OpenAI-Antwort: {str(e)}")

    def check_chapter(self, chapter_content: str, doc_info: Dokumenteninfo) -> str:
        """Prüft ein Kapitel des Brandschutzkonzepts auf Basis der Bauordnungen"""
        
        system_prompt = """Du bist ein Experte für Brandschutz und die Prüfung von Brandschutzkonzepten.
        Deine Aufgabe ist es, das vorliegende Kapitel eines Brandschutzkonzepts auf Basis der geltenden Bauordnungen und Vorschriften zu prüfen.
        
        Prüfe dabei insbesondere:
        - Ob die getroffenen Aussagen den geltenden Vorschriften entsprechen
        - Ob alle notwendigen Angaben vorhanden sind
        - Ob die Maßnahmen ausreichend sind
        - Ob Widersprüche zu den geltenden Vorschriften bestehen
        
        Formuliere deine Antwort als strukturierten Prüfbericht mit:
        1. Zusammenfassung der wichtigsten Aussagen
        2. Prüfergebnis mit Verweis auf die relevanten Vorschriften
        3. Festgestellte Mängel oder fehlende Angaben
        4. Empfehlungen zur Überarbeitung (falls notwendig)
        
        Referenziere alle Quellen nach jeder Aussage im Format (refX).
        """
        
        user_prompt = f"""
        Prüfe das folgende Kapitel eines Brandschutzkonzepts.
        
        Relevante Informationen zum Bauvorhaben:
        - Bauvorhaben: {doc_info.bauvorhaben}
        - Bundesland: {doc_info.bundesland}
        - Bauordnungsrechtliche Grundlagen: {', '.join(doc_info.bauordnungsrechtliche_grundlagen)}
        
        Zu prüfender Kapitelinhalt:
        {chapter_content}
        """
        
        try:
            response = self.client.chat.completions.create(
                model=self.model,
                temperature=0.1,
                max_tokens=4000,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
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
            
            return response.choices[0].message.content
            
        except Exception as e:
            raise Exception(f"Fehler bei der Prüfung des Kapitels: {str(e)}") 