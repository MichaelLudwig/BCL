import os
import json
import openai
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional

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

class Unterkapitel(BaseModel):
    titel: str = Field(description="Titel des Unterkapitels")
    nummer: Optional[str] = Field(description="Nummer des Unterkapitels (falls vorhanden)")
    inhalt: str = Field(description="Inhalt des Unterkapitels")

class Pruefbericht(BaseModel):
    zusammenfassung: str = Field(description="Zusammenfassung der wichtigsten Aussagen des Kapitels")
    pruefergebnis: str = Field(description="Detaillierte Prüfung mit Verweis auf relevante Vorschriften")
    maengel: List[str] = Field(description="Liste der festgestellten Mängel oder fehlenden Angaben")
    empfehlungen: List[str] = Field(description="Liste der Empfehlungen zur Überarbeitung")
    quellen: List[str] = Field(description="Liste der verwendeten Quellen im Format (refX)")

class KapitelPruefung(BaseModel):
    unterkapitel: List[Unterkapitel] = Field(description="Liste der zu prüfenden Unterkapitel")
    pruefberichte: List[Pruefbericht] = Field(description="Liste der Prüfberichte für die Unterkapitel")

    def __init__(self, **data):
        super().__init__(**data)
        if len(self.unterkapitel) != len(self.pruefberichte):
            raise ValueError("Anzahl der Unterkapitel muss mit Anzahl der Prüfberichte übereinstimmen")

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
        self.use_managed_identity = os.getenv('WEBSITE_INSTANCE_ID', False)

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

    def check_chapter(self, chapter_content: List[Dict[str, str]], doc_info: Dokumenteninfo) -> Dict[str, Any]:
        """Prüft alle Unterkapitel des Brandschutzkonzepts in einer Anfrage"""
        
        system_prompt = """Du bist ein Experte für Brandschutz und die Prüfung von Brandschutzkonzepten.
        Deine Aufgabe ist es, die vorliegenden Unterkapitel eines Brandschutzkonzepts auf Basis der geltenden Bauordnungen und Vorschriften zu prüfen.
        
        Prüfe für jedes Unterkapitel insbesondere:
        - Ob die getroffenen Aussagen den geltenden Vorschriften entsprechen
        - Ob alle notwendigen Angaben vorhanden sind
        - Ob die Maßnahmen ausreichend sind
        - Ob Widersprüche zu den geltenden Vorschriften bestehen
        
        Gib deine Antwort als Array von Prüfberichten zurück, wobei jeder Prüfbericht folgendes Format hat:
        {
            "zusammenfassung": "Kurze Zusammenfassung der wichtigsten Aussagen",
            "pruefergebnis": "Detaillierte Prüfung mit Verweis auf relevante Vorschriften",
            "maengel": ["Mangel 1", "Mangel 2", ...],
            "empfehlungen": ["Empfehlung 1", "Empfehlung 2", ...],
            "quellen": ["(ref1)", "(ref2)", ...]
        }
        
        Die Reihenfolge der Prüfberichte muss der Reihenfolge der übergebenen Unterkapitel entsprechen.
        Referenziere alle Quellen nach jeder Aussage im Format (refX).
        """
        
        # Formatiere die Unterkapitel für den Prompt
        chapters_text = "\n\n".join([
            f"Unterkapitel {i+1}: {chapter['title']}\n" +
            (f"Nummer: {chapter['number']}\n" if chapter.get('number') else "") +
            f"Inhalt:\n{chapter['content']}"
            for i, chapter in enumerate(chapter_content)
        ])
        
        user_prompt = f"""
        Prüfe die folgenden Unterkapitel eines Brandschutzkonzepts.
        
        Relevante Informationen zum Bauvorhaben:
        - Bauvorhaben: {doc_info.bauvorhaben}
        - Bundesland: {doc_info.bundesland}
        - Bauordnungsrechtliche Grundlagen: {', '.join(doc_info.bauordnungsrechtliche_grundlagen)}
        
        Zu prüfende Unterkapitel:
        {chapters_text}
        """
        
        try:
            # Authentifizierungskonfiguration basierend auf Environment
            search_auth = {
                "type": "system_assigned_managed_identity"
            } if self.use_managed_identity else {
                "type": "api_key",
                "key": os.getenv('AZURE_SEARCH_KEY')
            }

            print(f"Verwende Authentifizierung: {search_auth['type']}")  # Debug-Ausgabe
            
            response = self.client.chat.completions.create(
                model=self.model,
                temperature=0.1,
                max_tokens=10000,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                response_format={"type": "json_object"},
                extra_body={
                    "data_sources": [
                        {
                            "type": "azure_search",
                            "parameters": {
                                "endpoint": "https://searchbclapp.search.windows.net",
                                "index_name": "bcl-data2",
                                "authentication": search_auth,
                                "top_k": 5,
                                "fields_mapping": {
                                    "content_field": "chunk",
                                    "vector_fields": ["text_vector"],
                                    "title_field": "title",
                                    "metadata_fields": ["Bundesland", "Baukategorie"]
                                },
                                "hybrid_search": {
                                    "fields": ["text_vector"],
                                    "k": 5
                                }
                            }
                        }
                    ]
                }
            )
            
            # Debug-Ausgaben
            print(f"OpenAI Response Status: {response.model_dump_json()}")
            print(f"Response Content: {response.choices[0].message.content if response.choices else 'Keine Antwort'}")
            
            # Parse die JSON-Antwort in das Pydantic Model
            try:
                result = json.loads(response.choices[0].message.content)
            except json.JSONDecodeError as e:
                print(f"JSON Parsing Error: {str(e)}")
                print(f"Problematischer Content: {response.choices[0].message.content}")
                raise Exception(f"Ungültiges JSON-Format in der Antwort: {str(e)}")
                
            if not isinstance(result, list):
                result = [result]  # Fallback für den Fall, dass nur ein Bericht zurückgegeben wird
            
            pruefberichte = [Pruefbericht(**report) for report in result]
            
            # Formatiere die Prüfberichte als Text
            reports = []
            for pruefbericht in pruefberichte:
                report_text = f"""Zusammenfassung:
{pruefbericht.zusammenfassung}

Prüfergebnis:
{pruefbericht.pruefergebnis}

Festgestellte Mängel:
{"- " + chr(10).join("- " + m for m in pruefbericht.maengel) if pruefbericht.maengel else "Keine Mängel festgestellt"}

Empfehlungen:
{"- " + chr(10).join("- " + e for e in pruefbericht.empfehlungen) if pruefbericht.empfehlungen else "Keine Empfehlungen notwendig"}

Verwendete Quellen:
{"- " + chr(10).join("- " + q for q in pruefbericht.quellen) if pruefbericht.quellen else "Keine Quellen angegeben"}"""
                reports.append(report_text)
            
            return {
                "reports": reports,
                "citations": response.choices[0].message.context.get("citations", [])
            }
            
        except Exception as e:
            print(f"Fehler in check_chapter: {str(e)}")  # Debug-Ausgabe
            if hasattr(e, 'response'):
                print(f"API Response: {e.response}")  # Debug-Ausgabe
            raise Exception(f"Fehler bei der Prüfung der Unterkapitel: {str(e)}") 